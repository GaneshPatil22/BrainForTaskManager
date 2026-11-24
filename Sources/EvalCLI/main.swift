import ArgumentParser
import BrainCore
import BrainDatasets
import BrainEval
import BrainHarness
import BrainPipeline
import BrainProduction
import Foundation

@main
struct EvalCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "EvalCLI",
        abstract: "Run the eval suite, print the scorecard, enforce the regression gate.",
        subcommands: [Run.self, Scorecard_.self, Gate.self, PromoteBaseline.self, Diagnose.self],
        defaultSubcommand: Run.self)
}

// MARK: - Shared options

struct EvalOptions: ParsableArguments {
    @Option(name: .long, help: "Dataset split to evaluate: dev or test.")
    var split: String = "dev"

    @Option(name: .long, help: "Scenario directory.")
    var scenarios: String = "datasets/scenarios"

    @Option(name: .long, help: "Generated corpus, used for date-coverage.")
    var corpus: String = "datasets/generated"

    @Option(name: .long, help: "Category labels (title -> category JSON), if present.")
    var categoryLabels: String = "/tmp/category-truth.json"

    @Option(name: .long, help: "Synthetic capture dataset root.")
    var synthetic: String = "datasets/v1"

    @Option(name: .long, help: "Adversarial dataset directory.")
    var adversarial: String = "datasets/adversarial"

    @Option(name: .long, help: "Cassette mode: replay | record | live.")
    var cassettes: String = "replay"

    /// The test split is read at phase gates only. Enforced here rather than
    /// left to discipline (`docs/03-dataset-schema.md`).
    func validateSplit(isGate: Bool) throws {
        guard split == "test", !isGate else { return }
        throw ValidationError(
            """
            Refusing to evaluate the test split outside a gate run.

            The test split is read at phase gates only — never to tune a prompt,
            a threshold, a weight or a rule. Use `--split dev`, or run the gate
            deliberately with `EvalCLI gate --split test`.
            """)
    }
}

// MARK: - Building the scorecard

enum Runner {

    static func build(_ options: EvalOptions) async throws -> Scorecard {
        let all = try ScenarioLoader.loadAll(in: URL(fileURLWithPath: options.scenarios))
        let inSplit = all.filter { ($0.file.split ?? "dev") == options.split }
        let ranked = inSplit.filter { $0.file.expected != nil }

        var sets: [String: Int] = [
            "scenarios": inSplit.count,
            "ranked": ranked.count,
            "unranked": inSplit.count - ranked.count,
        ]

        // --- Ranking -------------------------------------------------------
        let rankingResult = Metrics.ranking(
            scenarios: ranked, weights: .default, policy: .default)
        let n = rankingResult.evaluated
        var rankingMetrics: [Metric] = []
        if n > 0 {
            let interval = 1.96 * (0.25 / Double(n)).squareRoot()
            rankingMetrics = [
                Metric(
                    name: "human pick in top-3", value: Double(rankingResult.top3) / Double(n),
                    unit: .percent, tolerance: 0.02, sampleSize: n,
                    note: String(format: "±%.0fpp at 95%%", interval * 100)),
                Metric(
                    name: "human pick is our top-1", value: Double(rankingResult.top1) / Double(n),
                    unit: .percent, tolerance: 0.03, sampleSize: n),
                Metric(
                    name: "NDCG@5", value: rankingResult.ndcgTotal / Double(n),
                    unit: .ratio, tolerance: 0.03, sampleSize: n),
            ]
        } else {
            rankingMetrics = [
                Metric(
                    name: "human pick in top-3", value: nil, unit: .percent,
                    note: "no ranked scenarios in this split — run `brain rank`")
            ]
        }

        // --- Synthetic captures: the T0 baseline -----------------------------
        let captures =
            (try? SyntheticLoader.load(
                directory: URL(fileURLWithPath: options.synthetic), split: options.split)) ?? []
        sets["synthetic captures"] = captures.count

        // --- Pipeline and recorded answers -----------------------------------
        //
        // **The scorecard walks the production ladder, in replay.** It used to
        // pass `router: nil`, which made "T2 rate" structurally 0.0% — a
        // number that could not move however much the pipeline escalated, and
        // which was quoted twice as evidence that quota is cheap. Replaying
        // recorded cassettes costs nothing and measures the real path.
        //
        // Limits are lifted for the same reason `brain compare` lifts them: a
        // replay fires a day of calls in a second and would otherwise trip the
        // per-minute ceiling, starving the very rungs being measured.
        let cassetteDirectory = URL(fileURLWithPath: "eval/cassettes")
        let replayStore = CassetteStore(directory: cassetteDirectory, mode: .replay)
        let replayLedger = BudgetLedger()
        let replayRouter = await ProductionRouter.make(
            apiKey: "", ledger: replayLedger, cassettes: replayStore, mode: .replay)
        // **After `make`, never before.** `ProductionRouter.make` writes the
        // verified free-tier limits onto the ledger itself, so lifting them
        // first is lifting nothing. Written in the wrong order first time, and
        // the "escalations answered from a recording" metric below caught it
        // on its first run: 190 of 425, the remaining 235 refused on a
        // per-minute ceiling that cannot apply to a recording.
        for model in ["gemini-decision-1", "gemma-4-26b-a4b-it", "gemini-3.1-flash-lite"] {
            await replayLedger.setLimits(.unlimited, for: model)
        }

        let pipelineResult = await Metrics.pipeline(
            texts: captures.map(\.rawText),
            timeZone: TimeZone(identifier: "Asia/Kolkata")!, now: SyntheticLoader.now,
            router: replayRouter)
        let replayStats = await replayStore.stats()
        let audit = Metrics.auditCassettes(directory: cassetteDirectory)
        sets["recorded answers"] = audit.answers

        let lost = pipelineResult.captures - pipelineResult.items
        let t0Settled = pipelineResult.byTier[.t0] ?? 0
        let t2Settled = pipelineResult.byTier[.t2] ?? 0

        let ext = Metrics.extraction(
            captures: captures, timeZone: TimeZone(identifier: "Asia/Kolkata")!,
            now: SyntheticLoader.now)

        func rate(_ pair: (correct: Int, attempted: Int, expected: Int)) -> Double? {
            pair.expected == 0 ? nil : Double(pair.correct) / Double(pair.expected)
        }
        let t0Baseline: [Metric] =
            captures.isEmpty
            ? [
                Metric(
                    name: "type accuracy", value: nil, unit: .percent,
                    note: "no synthetic captures — run scripts/make-synthetic.py")
            ]
            : [
                Metric(
                    name: "type accuracy", value: rate(ext.type), unit: .percent,
                    tolerance: 0.02, sampleSize: ext.type.expected,
                    note: "labels true by construction; see docs/14"),
                Metric(
                    name: "type — unfamiliar verb",
                    value: ext.typeOnUnknownVerb.total == 0
                        ? nil
                        : Double(ext.typeOnUnknownVerb.correct)
                            / Double(ext.typeOnUnknownVerb.total),
                    unit: .percent, tolerance: 0.03,
                    sampleSize: ext.typeOnUnknownVerb.total,
                    note: "the only non-circular slice — verb absent from our lexicon"),
                Metric(
                    name: "date accuracy", value: rate(ext.date), unit: .percent,
                    tolerance: 0.01, sampleSize: ext.date.expected),
                Metric(
                    name: "effort accuracy", value: rate(ext.effort), unit: .percent,
                    tolerance: 0.02, sampleSize: ext.effort.expected),
                Metric(
                    name: "dependency recall", value: rate(ext.dependency), unit: .percent,
                    tolerance: 0.03, sampleSize: ext.dependency.expected),
                Metric(
                    name: "span-verified rate",
                    value: ext.spansChecked == 0
                        ? nil : Double(ext.spansVerified) / Double(ext.spansChecked),
                    unit: .percent, tolerance: 0.0, sampleSize: ext.spansChecked),
            ]

        // --- T0 coverage ---------------------------------------------------
        let coverage = Metrics.t0Coverage(scenarios: inSplit)
        let t0Metrics: [Metric] = [
            Metric(
                name: "category resolved at T0",
                value: coverage.items == 0
                    ? nil : Double(coverage.categoryResolved) / Double(coverage.items),
                unit: .percent, tolerance: 0.05, sampleSize: coverage.items),
            Metric(
                name: "T0 settled",
                value: pipelineResult.fieldsConsidered == 0
                    ? nil : Double(t0Settled) / Double(pipelineResult.fieldsConsidered),
                unit: .percent, tolerance: 0.05,
                sampleSize: pipelineResult.fieldsConsidered,
                note: "fields resolved with no model at all — drive this up"),
            // **Renamed, not retuned.** The old "T2 rate (costs quota)" was
            // computed on a router-less path and was therefore 0.0% by
            // construction. This one measures something, so it is a different
            // metric and carries a different name; the gate has no baseline
            // for it until one is promoted, which is correct — there is
            // nothing to regress against yet.
            Metric(
                name: "T2 settled, routed (costs quota)",
                value: !pipelineResult.routerAttached || pipelineResult.fieldsConsidered == 0
                    ? nil : Double(t2Settled) / Double(pipelineResult.fieldsConsidered),
                unit: .percent, tolerance: 0.05, higherIsBetter: false,
                sampleSize: pipelineResult.fieldsConsidered,
                note: pipelineResult.routerAttached
                    ? "\(pipelineResult.escalations) escalations over "
                        + "\(pipelineResult.captures) captures — drive this down, it is the "
                        + "only thing that costs quota"
                    : "no router attached — not measured"),
            // A low T2 rate means one of two opposite things: the rules are
            // doing the work, or the ladder never reached a recording. Twice
            // now it has been the second, so the reach is its own number
            // rather than a footnote on the first.
            Metric(
                name: "escalations answered from a recording",
                value: pipelineResult.escalations == 0
                    ? nil
                    : Double(pipelineResult.answeredFromRecording)
                        / Double(pipelineResult.escalations),
                unit: .percent, tolerance: 0.02,
                sampleSize: pipelineResult.escalations,
                note: "\(pipelineResult.answeredFromRecording) of "
                    + "\(pipelineResult.escalations) · store: \(replayStats.hits) hit / "
                    + "\(replayStats.misses) miss — below 100% means a rung had no "
                    + "recording and the rate above reads low for the wrong reason; "
                    + "record with `brain record --escalations-only`"),
        ]

        // --- Category ------------------------------------------------------
        var categoryMetrics: [Metric] = []
        if let data = try? Data(contentsOf: URL(fileURLWithPath: options.categoryLabels)),
            let labels = try? JSONDecoder().decode([String: String].self, from: data)
        {
            let result = Metrics.category(labels: labels)
            sets["category labels"] = result.total
            categoryMetrics = [
                Metric(
                    name: "accuracy on attempted",
                    value: result.attempted == 0
                        ? nil : Double(result.correct) / Double(result.attempted),
                    unit: .percent, tolerance: 0.02, sampleSize: result.attempted),
                Metric(
                    name: "coverage", value: Double(result.attempted) / Double(result.total),
                    unit: .percent, tolerance: 0.05, sampleSize: result.total,
                    note: "labels are generator-assigned — agreement, not correctness"),
            ]
        } else {
            categoryMetrics = [
                Metric(
                    name: "accuracy on attempted", value: nil, unit: .percent,
                    note: "no labels — run scripts/category-truth.py")
            ]
        }

        // --- Dates ---------------------------------------------------------
        let corpusFiles =
            (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: options.corpus), includingPropertiesForKeys: nil
            )
            .filter { $0.pathExtension == "brain" }) ?? []
        let dateResult = Metrics.dates(
            corpus: corpusFiles, timeZone: TimeZone(identifier: "Asia/Kolkata")!,
            now: SyntheticLoader.now)
        sets["distinct date phrasings"] = dateResult.total
        let dateMetrics: [Metric] = [
            Metric(
                name: "date phrasings parsed",
                value: dateResult.total == 0
                    ? nil : Double(dateResult.parsed) / Double(dateResult.total),
                unit: .percent, tolerance: 0.0, sampleSize: dateResult.total,
                note: dateResult.unparseable.isEmpty
                    ? nil
                    : "unparsed: " + dateResult.unparseable.prefix(5).joined(separator: ", "))
        ]

        // --- Adversarial -----------------------------------------------------
        let adversarialCases =
            (try? AdversarialLoader.load(directory: URL(fileURLWithPath: options.adversarial)))
            ?? []
        let injectionResult = await Metrics.injection(
            cases: adversarialCases,
            directory: URL(fileURLWithPath: "eval/cassettes"),
            allowed: ItemType.allCases.map(\.rawValue),
            systemPrompt: Prompts.classifyTypeSystem,
            promptVersion: Prompts.version,
            model: "gemini-decision-1")
        let adv = Metrics.adversarial(
            cases: adversarialCases, timeZone: TimeZone(identifier: "Asia/Kolkata")!,
            now: SyntheticLoader.now)
        sets["adversarial"] = adversarialCases.count

        // --- Robustness ------------------------------------------------------
        let robustness: [Metric] = [
            Metric(
                name: "captures lost",
                value: pipelineResult.captures == 0 ? nil : Double(lost),
                unit: .count, mustNotExceed: 0, higherIsBetter: false,
                sampleSize: pipelineResult.captures,
                note: "invariant — a capture is never lost, whatever fails"),
            Metric(
                name: "hallucinated-ID rate",
                value: audit.answers == 0 ? nil : Double(audit.outOfSet) / Double(audit.answers),
                unit: .percent, mustNotExceed: 0, higherIsBetter: false,
                sampleSize: audit.answers,
                note: audit.examples.isEmpty
                    ? "every recorded answer was inside the option set"
                    : "out of set: " + audit.examples.prefix(2).joined(separator: " | ")),
            Metric(
                name: "answers needing rescue",
                value: audit.answers == 0
                    ? nil : Double(audit.neededNormalising) / Double(audit.answers),
                unit: .percent, tolerance: 0.05, higherIsBetter: false,
                sampleSize: audit.answers,
                note: "guard 3 normalised these rather than discarding them"),
            Metric(
                name: "adversarial handled",
                value: adv.scored == 0 ? nil : Double(adv.passed) / Double(adv.scored),
                unit: .percent, tolerance: 0.0, sampleSize: adv.scored,
                note: adv.failures.isEmpty
                    ? "\(adv.deferred) injection rows deferred to B3"
                    : adv.failures.prefix(2).joined(separator: " | ")),
            Metric(
                name: "adversarial over budget",
                value: Double(adv.tooSlow.count), unit: .count,
                mustNotExceed: 0, higherIsBetter: false,
                note: adv.tooSlow.isEmpty
                    ? String(format: "slowest %.1fms", adv.slowestMs)
                    : adv.tooSlow.joined(separator: ", ")),
            Metric(
                name: "ranking deterministic",
                value: Metrics.isDeterministic(scenarios: inSplit) ? 1 : 0,
                unit: .boolean, tolerance: 0.0),
            Metric(
                name: "graphs with cycles",
                value: Double(Metrics.cycleCount(scenarios: inSplit)),
                unit: .count, mustNotExceed: 0, higherIsBetter: false,
                note: "invariant — any value above 0 fails unconditionally"),

            Metric(
                name: "injection containment",
                value: injectionResult.recorded == 0
                    ? nil
                    : Double(injectionResult.contained) / Double(injectionResult.recorded),
                unit: .percent, mustNotExceed: nil, sampleSize: injectionResult.recorded,
                note: "STRUCTURAL, not behavioural — a closed-set answer has no "
                    + "vocabulary to comply in. Holds only while no tools exist."),
        ]

        // --- Systems ---------------------------------------------------------
        let timing = Metrics.latencies(scenarios: inSplit)
        let systems: [Metric] = [
            Metric(
                name: "p50 latency", value: timing.p50, unit: .milliseconds,
                tolerance: 1.0, higherIsBetter: false),
            Metric(
                name: "p95 latency", value: timing.p95, unit: .milliseconds,
                tolerance: 2.0, higherIsBetter: false),
            Metric(
                name: "tokens per escalation",
                value: audit.answers == 0 ? nil : Double(audit.totalTokens / audit.answers),
                unit: .count, tolerance: 50, higherIsBetter: false,
                sampleSize: audit.answers,
                note: "the real currency on a free tier — rupees are zero and "
                    + "say nothing about whether we can afford to run"),
            Metric(
                name: "escalations/day affordable",
                value: audit.answers == 0
                    ? nil
                    // Decision 1: 10,000 RPD, 50,000 TPM. Whichever binds first.
                    : Double(
                        min(10_000, 50_000 * 60 * 24 / max(audit.totalTokens / audit.answers, 1))),
                unit: .count, tolerance: 500,
                note: "at the measured token cost, against the verified free-tier caps"),
        ]

        return Scorecard(
            runId: ULID(
                timestampMilliseconds: UInt64(Date().timeIntervalSince1970 * 1000),
                randomness: (0..<10).map { _ in UInt8.random(in: 0...255) }
            ).rawValue,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            dataset: "v1", split: options.split, sets: sets,
            sections: [
                Section(name: "ranking", metrics: rankingMetrics),
                Section(name: "tiering", metrics: t0Metrics),
                Section(name: "category", metrics: categoryMetrics),
                Section(name: "t0 baseline", metrics: t0Baseline),
                Section(name: "extraction", metrics: dateMetrics),
                Section(name: "robustness", metrics: robustness),
                Section(name: "systems", metrics: systems),
            ])
    }

    static func baselineURL(_ split: String) -> URL {
        URL(fileURLWithPath: "eval/baselines/\(split).json")
    }

    static func loadBaseline(_ split: String) -> Scorecard? {
        guard let data = try? Data(contentsOf: baselineURL(split)) else { return nil }
        return try? JSONDecoder().decode(Scorecard.self, from: data)
    }
}

// MARK: - Commands

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run", abstract: "Run the suite and print the scorecard.")
    @OptionGroup var options: EvalOptions

    func run() async throws {
        try options.validateSplit(isGate: false)
        let card = try await Runner.build(options)
        print(card.render(baseline: Runner.loadBaseline(options.split)))
    }
}

struct Scorecard_: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scorecard", abstract: "Print the scorecard table.")
    @OptionGroup var options: EvalOptions

    func run() async throws {
        try options.validateSplit(isGate: false)
        let card = try await Runner.build(options)
        print(card.render(baseline: Runner.loadBaseline(options.split)))
    }
}

struct Gate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gate",
        abstract: "Fail if any key metric has regressed beyond tolerance.")
    @OptionGroup var options: EvalOptions

    func run() async throws {
        let card = try await Runner.build(options)
        guard let baseline = Runner.loadBaseline(options.split) else {
            print(card.render(baseline: nil))
            print(
                """
                GATE: SKIPPED — no baseline at \(Runner.baselineURL(options.split).path)

                Create one deliberately:
                    swift run EvalCLI promote-baseline --split \(options.split) \\
                        --reason "first baseline"
                """)
            return
        }

        print(card.render(baseline: baseline))
        let result = card.gate(against: baseline)
        if !result.improvements.isEmpty {
            print("Improved: " + result.improvements.joined(separator: ", "))
            print("(Improvements never auto-update the baseline — promote it deliberately.)")
        }
        if result.isPass {
            print("\nGATE: PASS")
        } else {
            print("\nGATE: FAIL — \(result.failures.count) metric(s) outside tolerance")
            for failure in result.failures { print("  • \(failure)") }
            throw ExitCode.failure
        }
    }
}

struct PromoteBaseline: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "promote-baseline",
        abstract: "Store the current scorecard as the baseline. A deliberate act.")
    @OptionGroup var options: EvalOptions

    @Option(name: .long, help: "Why this baseline is being promoted. Required.")
    var reason: String

    func run() async throws {
        let card = try await Runner.build(options)
        let url = Runner.baselineURL(options.split)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(card).write(to: url)

        print(card.render(baseline: nil))
        print(
            """
            Baseline written to \(url.path)
            Reason: \(reason)

            Commit it — a baseline that is not in git cannot gate anything.
            """)
    }
}
