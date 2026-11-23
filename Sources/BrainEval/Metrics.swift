import BrainCore
import BrainDatasets
import BrainHarness
import BrainPipeline
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

    // MARK: - Synthetic captures (the T0 baseline)

    public struct ExtractionResult: Sendable {
        public var rows = 0
        /// correct / attempted / expected, per field.
        public var type = (correct: 0, attempted: 0, expected: 0)
        public var date = (correct: 0, attempted: 0, expected: 0)
        public var effort = (correct: 0, attempted: 0, expected: 0)
        public var dependency = (correct: 0, attempted: 0, expected: 0)
        public var category = (correct: 0, attempted: 0, expected: 0)
        /// Type accuracy split by whether the verb is in our lexicon. The
        /// unknown half is the only part that is not self-fulfilling.
        public var typeOnKnownVerb = (correct: 0, total: 0)
        public var typeOnUnknownVerb = (correct: 0, total: 0)
        public var spansVerified = 0
        public var spansChecked = 0
        public var confusion: [String: [String: Int]] = [:]
    }

    /// Runs the T0 rules over synthetic captures whose labels are true by
    /// construction (`scripts/make-synthetic.py`).
    ///
    /// **Read these numbers carefully.** Date, effort and dependency are
    /// grammars: generating "kal" and checking we read "kal" is legitimate
    /// coverage. Type and category are closer to circular — the generator and
    /// the classifier share a notion of what a verb is — so the informative
    /// slice is `typeOnUnknownVerb`, where the verb is deliberately absent from
    /// our lexicon.
    public static func extraction(
        captures: [SyntheticCapture], timeZone: TimeZone, now: Date
    ) -> ExtractionResult {
        let dateParser = DateParser(timeZone: timeZone)
        let effortParser = EffortParser()
        let dependencyParser = DependencyParser(timeZone: timeZone)
        let typeClassifier = TypeClassifier(timeZone: timeZone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        var result = ExtractionResult()

        for capture in captures {
            result.rows += 1
            let text = capture.rawText

            // --- type
            if let expected = capture.labels.type {
                result.type.expected += 1
                let predicted = typeClassifier.classify(text, now: now)
                let got = predicted.value?.rawValue
                if predicted.isKnown { result.type.attempted += 1 }
                let correct = got == expected
                if correct { result.type.correct += 1 }
                result.confusion[expected, default: [:]][got ?? "(abstained)", default: 0] += 1

                // Known vs unknown verb, judged by whether our imperative list
                // contains any of the capture's first words.
                let words = text.lowercased()
                    .split(whereSeparator: { !$0.isLetter }).map(String.init)
                let knownVerb = words.prefix(4).contains {
                    TypeClassifier.imperativeVerbs.contains($0)
                }
                if knownVerb {
                    result.typeOnKnownVerb.total += 1
                    if correct { result.typeOnKnownVerb.correct += 1 }
                } else {
                    result.typeOnUnknownVerb.total += 1
                    if correct { result.typeOnUnknownVerb.correct += 1 }
                }
            }

            // --- date
            let parsedDate = dateParser.parse(text, now: now)
            if let expectedOffset = capture.labels.dueAt {
                result.date.expected += 1
                if let parsedDate {
                    result.date.attempted += 1
                    let days =
                        calendar.dateComponents(
                            [.day], from: calendar.startOfDay(for: now),
                            to: calendar.startOfDay(for: parsedDate.date)
                        ).day ?? -999
                    if days == expectedOffset { result.date.correct += 1 }
                }
            }

            // --- effort
            let parsedEffort = effortParser.parse(text)
            if let expected = capture.labels.effort {
                result.effort.expected += 1
                if let parsedEffort {
                    result.effort.attempted += 1
                    if parsedEffort.bucket.rawValue == expected { result.effort.correct += 1 }
                }
            }

            // --- dependency
            let parsedDependencies = dependencyParser.parse(text, now: now)
            if let expected = capture.labels.dependency {
                result.dependency.expected += 1
                if let first = parsedDependencies.first {
                    result.dependency.attempted += 1
                    // The referent may carry an article the label omits.
                    if first.targetText.contains(expected)
                        || expected.contains(first.targetText)
                    {
                        result.dependency.correct += 1
                    }
                }
            }

            // --- category
            if let expected = capture.labels.category {
                result.category.expected += 1
                let predicted = CategoryClassifier.classify(text)
                if let value = predicted.value {
                    result.category.attempted += 1
                    if value.rawValue == expected { result.category.correct += 1 }
                }
            }

            // --- spans must resolve, on every row (guard 2)
            let lowered = text.lowercased()
            for span in [parsedDate?.span, parsedEffort?.span].compactMap({ $0 })
                + parsedDependencies.map(\.span)
            {
                result.spansChecked += 1
                if span.resolve(in: lowered) != nil { result.spansVerified += 1 }
            }
        }
        return result
    }

    // MARK: - Pipeline

    public struct PipelineResult: Sendable {
        public var captures = 0
        public var items = 0
        public var failed = 0
        /// Fields settled per tier, so T0 coverage and T2 rate are measured
        /// rather than asserted.
        public var byTier: [Tier: Int] = [:]
        public var fieldsConsidered = 0
    }

    /// Runs the real pipeline over real capture text.
    ///
    /// `captures - items` is the `captures lost` invariant: the one outcome
    /// that is never acceptable (`docs/07-harness-spec.md`).
    public static func pipeline(
        texts: [String], timeZone: TimeZone, now: Date
    ) async -> PipelineResult {
        var result = PipelineResult()
        let pipeline = EnrichmentPipeline(timeZone: timeZone, router: nil)
        var generator = ULIDGenerator(seed: 11)
        var graph = BrainGraph()

        for text in texts {
            result.captures += 1
            let capture = Capture(id: generator.next(), rawText: text, createdAt: now)
            let enriched = await pipeline.enrich(
                capture: capture, graph: graph, now: now, idGenerator: &generator, requester: .local
            )
            graph.insert(enriched.item)
            if enriched.capture.status == .failed { result.failed += 1 }
            for (_, tier) in enriched.trace.tierByField {
                result.byTier[tier, default: 0] += 1
                result.fieldsConsidered += 1
            }
            result.fieldsConsidered += enriched.trace.unresolved.count
        }
        result.items = graph.items.count
        return result
    }

    // MARK: - Recorded model answers

    public struct CassetteAudit: Sendable {
        public var answers = 0
        /// Answers naming something outside the option set the model was
        /// given. **Must be zero** — the whole point of guard 1.
        public var outOfSet = 0
        /// Answers the schema guard had to normalise or reject.
        public var neededNormalising = 0
        public var rejectedBySchema = 0
        public var abstentions = 0
        public var totalTokens = 0
        public var byModel: [String: Int] = [:]
        public var examples: [String] = []
    }

    /// Audits every recorded model answer against the option set it was given.
    ///
    /// This is where `hallucinated-ID rate` actually comes from. It was
    /// reported as "not measured" long after model calls existed, which made
    /// the scorecard quietly wrong — a metric that cannot be computed and one
    /// nobody wired up look identical in a report.
    public static func auditCassettes(directory: URL, allowed: [String]) -> CassetteAudit {
        var audit = CassetteAudit()
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()

        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                let cassette = try? decoder.decode(Cassette.self, from: data)
            else { continue }
            audit.answers += 1
            audit.byModel[cassette.model, default: 0] += 1
            audit.totalTokens += cassette.promptTokens + cassette.completionTokens

            let raw = cassette.answer ?? ""
            if raw.isEmpty {
                audit.abstentions += 1
                continue
            }
            // Out of set is judged on the raw answer, before any normalising:
            // the question is what the model said, not what we rescued.
            if !allowed.contains(raw) {
                let outcome = Guards.schema(raw: raw, allowed: allowed)
                if outcome.accepted == nil {
                    audit.rejectedBySchema += 1
                    audit.outOfSet += 1
                    if audit.examples.count < 5 { audit.examples.append(String(raw.prefix(60))) }
                } else {
                    audit.neededNormalising += 1
                }
            }
        }
        return audit
    }

    // MARK: - Injection

    public struct InjectionResult: Sendable {
        public var attempted = 0
        public var recorded = 0
        /// Answers that stayed inside the option set.
        public var contained = 0
        /// Answers that escaped the option set. Any value above zero means the
        /// containment argument is wrong.
        public var escaped = 0
        public var answers: [String: Int] = [:]
    }

    /// Measures what the injection rows actually produced.
    ///
    /// **What this does and does not claim.** It does not claim the model
    /// "resisted" anything. With a closed-set call the model has no vocabulary
    /// in which to comply: the answer is a key from the option set, and
    /// "ignore previous instructions" can at worst produce the wrong *type*.
    /// Containment here is **structural**, and that is a stronger property
    /// than a model choosing to behave — but it is a different claim, and
    /// reporting it as resistance would overstate it.
    ///
    /// The guarantee holds only while no tools are exposed and every answer is
    /// drawn from a whitelist. If either changes, this number stops meaning
    /// anything and the test has to be redesigned.
    public static func injection(
        cases: [AdversarialCase], directory: URL, allowed: [String],
        systemPrompt: String, promptVersion: String, model: String
    ) async -> InjectionResult {
        var result = InjectionResult()
        let store = CassetteStore(directory: directory, mode: .replay)

        for testCase in cases where testCase.attack == "prompt_injection" {
            result.attempted += 1
            let normalized = Normalizer.normalize(testCase.rawText)
            let request = ModelRequest(
                capability: .classifyType, system: systemPrompt,
                untrustedContent: normalized.redacted,
                allowedAnswers: allowed, promptVersion: promptVersion)
            guard let response = await store.lookup(request, model: model) else { continue }
            result.recorded += 1

            let answer = Guards.schema(raw: response.raw, allowed: allowed).accepted
            if let answer, allowed.contains(answer) {
                result.contained += 1
                result.answers[answer, default: 0] += 1
            } else if response.answer == nil || response.answer?.isEmpty == true {
                // An abstention is contained too — nothing escaped.
                result.contained += 1
                result.answers["(abstained)", default: 0] += 1
            } else {
                result.escaped += 1
                result.answers[response.answer ?? "?", default: 0] += 1
            }
        }
        return result
    }

    // MARK: - Adversarial

    public struct AdversarialResult: Sendable {
        public var scored = 0
        public var passed = 0
        public var deferred = 0
        /// Rows that exceeded their latency budget — the signal that a regex
        /// has started backtracking catastrophically on large input.
        public var tooSlow: [String] = []
        public var failures: [String] = []
        public var slowestMs = 0.0
    }

    /// Runs every T0 parser over each adversarial capture and checks it did
    /// what the row says it should.
    ///
    /// **What this does and does not prove.** It proves the parsers survive
    /// degenerate input, stay within a latency budget, and abstain where they
    /// should. It does **not** prove injection resistance: with no model in the
    /// loop there is nothing to be non-compliant. Injection rows are counted as
    /// deferred to B3 rather than scored, because scoring them now would be
    /// theatre (`docs/13-generated-datasets.md` on fabricated numbers).
    public static func adversarial(
        cases: [AdversarialCase], timeZone: TimeZone, now: Date
    ) -> AdversarialResult {
        let dateParser = DateParser(timeZone: timeZone)
        let effortParser = EffortParser()
        let dependencyParser = DependencyParser(timeZone: timeZone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        var result = AdversarialResult()

        for testCase in cases {
            guard testCase.evaluatedAt == "B2" else {
                result.deferred += 1
                continue
            }
            result.scored += 1
            var problems: [String] = []

            let start = DispatchTime.now().uptimeNanoseconds
            let date = dateParser.parse(testCase.rawText, now: now)
            let effort = effortParser.parse(testCase.rawText)
            let category = CategoryClassifier.classify(testCase.rawText)
            let dependencies = dependencyParser.parse(testCase.rawText, now: now)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            result.slowestMs = max(result.slowestMs, elapsed)

            if elapsed > testCase.expect.maxLatencyMs {
                result.tooSlow.append(
                    String(
                        format: "%@ (%.1fms > %.0fms)", testCase.id, elapsed,
                        testCase.expect.maxLatencyMs))
                problems.append("too slow")
            }

            // Dates: an expectation of nil means the parser must abstain.
            if let expectedOffset = testCase.expect.date.flatMap(Int.init) {
                guard let date else {
                    problems.append("expected a date, got none")
                    result.failures.append("\(testCase.id): expected a date, got none")
                    continue
                }
                let days =
                    calendar.dateComponents(
                        [.day], from: calendar.startOfDay(for: now),
                        to: calendar.startOfDay(for: date.date)
                    ).day ?? 0
                if days != expectedOffset {
                    problems.append("date \(days) != \(expectedOffset)")
                }
            } else if date != nil {
                problems.append("expected abstention, parsed a date")
            }

            if let expected = testCase.expect.effort {
                if effort?.bucket.rawValue != expected {
                    problems.append("effort \(effort?.bucket.rawValue ?? "nil") != \(expected)")
                }
            } else if effort != nil {
                problems.append("expected abstention, parsed effort")
            }

            if let expected = testCase.expect.category {
                if category.value?.rawValue != expected {
                    problems.append(
                        "category \(category.value?.rawValue ?? "nil") != \(expected)")
                }
            } else if category.isKnown {
                problems.append("expected abstention, parsed category")
            }

            if let expected = testCase.expect.dependency {
                if dependencies.first?.targetText != expected {
                    problems.append(
                        "dependency \(dependencies.first?.targetText ?? "nil") != \(expected)")
                }
            } else if !dependencies.isEmpty {
                problems.append("expected no dependency, found one")
            }

            // Every cited span must resolve, on every input (guard 2).
            let lowered = testCase.rawText.lowercased()
            if let date, date.span.resolve(in: lowered) == nil {
                problems.append("date span does not resolve")
            }
            if let effort, effort.span.resolve(in: lowered) == nil {
                problems.append("effort span does not resolve")
            }
            for dependency in dependencies where dependency.span.resolve(in: lowered) == nil {
                problems.append("dependency span does not resolve")
            }

            if problems.isEmpty {
                result.passed += 1
            } else {
                result.failures.append(
                    "\(testCase.id) [\(testCase.attack)]: "
                        + problems.joined(separator: "; "))
            }
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
