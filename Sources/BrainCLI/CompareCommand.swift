import ArgumentParser
import BrainCore
import BrainDatasets
import BrainEval
import BrainHarness
import BrainPipeline
import BrainProduction
import Foundation

/// Runs two paths over the same captures and prints them side by side.
///
/// **Why this exists.** The argument for moving understanding from rules to a
/// model is an argument, and the argument for keeping the rules is also an
/// argument. The scorecard cannot settle it: it reports which *tier* answered,
/// not whether the answer was right, so a path that answers more fields looks
/// better even if the extra answers are wrong.
///
/// This measures the thing that matters to a user — **of everything that
/// should have been answered, how much was answered correctly** — for each
/// path, on identical input, against identical labels.
///
/// **It cannot settle the question on its own, and should not be read as if
/// it could.** The labels come from the generator that wrote the captures, so
/// the rules were authored against the same distribution they are scored on.
/// A model that has never seen that generator is at a real disadvantage here.
/// Read a model win as strong and a rules win as weak, and get the real answer
/// from labelled captures of Ganesh's own.
struct CompareCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compare",
        abstract: "Score two enrichment paths on the same captures and labels.",
        discussion: """
            Path A is the rules alone. Path B adds the model ladder behind \
            them, so a field the rules abstain on is escalated instead of \
            left blank.

            Replay is the default and spends nothing. With no cassettes for a \
            capability the model simply abstains, the two paths come out \
            identical, and the "model calls" row says why.
            """)

    @Option(name: .long, help: "Dataset split: dev, test or train.")
    var split: String = "dev"

    @Option(name: .long, help: "IANA timezone.")
    var timezone: String = "Asia/Kolkata"

    @Option(name: .long, help: "Where cassettes live.")
    var cassettes: String = "eval/cassettes"

    @Flag(name: .long, help: "Call the real models. Spends quota; needs GOOGLE_AI_API_KEY.")
    var live = false

    @Option(name: .long, help: "Score only the first N captures.")
    var limit: Int = 100_000

    @Option(
        name: .long,
        help: "Comma-separated flags for path B: category. Empty means none.")
    var features: String = ""

    /// Parsed once so an unknown name is a usage error rather than a silently
    /// ignored word — a typo here would otherwise print a "no change" table
    /// and look like a finding.
    func parsedFeatures() throws -> EnrichmentFeatures {
        var set = EnrichmentFeatures.none
        for name in features.split(separator: ",").map({
            $0.trimmingCharacters(in: .whitespaces)
        }) where !name.isEmpty {
            switch name {
            case "category": set.insert(.categoryEscalation)
            default: throw ValidationError("unknown feature: \(name). Known: category.")
            }
        }
        return set
    }

    func run() async throws {
        guard let zone = TimeZone(identifier: timezone) else {
            throw ValidationError("unknown timezone: \(timezone)")
        }
        let captures = Array(
            try SyntheticLoader.load(
                directory: URL(fileURLWithPath: "datasets/v1"), split: split
            ).prefix(limit))
        guard !captures.isEmpty else { throw ValidationError("no captures in split \(split)") }

        let key = ProcessInfo.processInfo.environment["GOOGLE_AI_API_KEY"] ?? ""
        if live && key.isEmpty {
            throw ValidationError("--live needs GOOGLE_AI_API_KEY in the environment.")
        }
        let store = CassetteStore(
            directory: URL(fileURLWithPath: cassettes), mode: live ? .record : .replay)
        // **Replaying a cassette spends nothing, so the budget must not
        // apply.** Found by this command reporting a near-zero effect and
        // being wrong about why: it fires a whole day of calls in a few
        // seconds, which blows Decision 1's *per-minute* ceiling (50,000
        // tokens) within the first second. The router then correctly skips
        // every later rung as "budget", and the comparison silently measures
        // a starved path instead of the real one. 129 category cassettes were
        // on disk with real answers and only 3 reached the pipeline.
        //
        // Live runs keep their limits, because those calls do cost.
        let ledger = BudgetLedger()
        let router = await ProductionRouter.make(
            apiKey: key, ledger: ledger, cassettes: store,
            mode: live ? .live : .replay)
        if !live {
            for model in ["gemini-decision-1", "gemma-4-26b-a4b-it", "gemini-3.1-flash-lite"] {
                await ledger.setLimits(.unlimited, for: model)
            }
        }

        let now = SyntheticLoader.now
        let rules = await Metrics.comparePath(
            name: "rules only", captures: captures,
            pipeline: EnrichmentPipeline(timeZone: zone), timeZone: zone, now: now)
        let flags = try parsedFeatures()
        let hybrid = await Metrics.comparePath(
            name: "rules + model", captures: captures,
            pipeline: EnrichmentPipeline(timeZone: zone, router: router, features: flags),
            timeZone: zone, now: now)

        // Cassette hits are the difference between "the model did not help"
        // and "the model was never reached". Printed always, because reading
        // the first as the second is the exact mistake this command is for.
        let stats = await store.stats()
        Self.render(
            rules, hybrid, split: split, live: live,
            features: features.isEmpty ? "none" : features, cassettes: stats)
    }

    static func render(
        _ a: Metrics.PathResult, _ b: Metrics.PathResult, split: String, live: Bool,
        features: String, cassettes: (hits: Int, misses: Int, recorded: Int)
    ) {
        func pct(_ value: Double) -> String { String(format: "%5.1f%%", value * 100) }

        print(
            """

            PATH COMPARISON   split \(split) · \(a.rows) captures · \
            \(live ? "LIVE" : "replay") · flags: \(features)

              end-to-end = correct / should-have-been-answered. The user-facing
              number: a field left blank counts against it, exactly as a wrong
              answer does.

            """)
        print("  field      path            answered   of   correct   end-to-end   delta")
        print("  " + String(repeating: "-", count: 72))

        for ((name, left), (_, right)) in zip(a.fields, b.fields) {
            let delta = right.endToEnd - left.endToEnd
            for (path, score) in [(a.name, left), (b.name, right)] {
                let isSecond = path == b.name
                let deltaText =
                    isSecond
                    ? (abs(delta) < 0.0005
                        ? "      ="
                        : String(format: "%+7.1fpp", delta * 100))
                    : ""
                print(
                    "  \(Printer.pad(isSecond ? "" : name, 10)) "
                        + "\(Printer.pad(path, 15)) "
                        + "\(Printer.pad("\(score.attempted)", 9)) "
                        + "\(Printer.pad("\(score.expected)", 5)) "
                        + "\(Printer.pad("\(score.correct)", 8)) "
                        + "  \(pct(score.endToEnd))     \(deltaText)")
            }
            print("")
        }

        let escalated = b.fields.filter { $0.1.modelAnswered > 0 }
        if !escalated.isEmpty {
            print("  What the model actually answered, and how much of it could be scored:")
            for (name, score) in escalated {
                let scored = score.modelAnswered - score.modelAnsweredUnlabelled
                print(
                    "    \(Printer.pad(name, 10)) answered \(score.modelAnswered), "
                        + "scored \(scored), unlabelled \(score.modelAnsweredUnlabelled)")
            }
            if escalated.contains(where: { $0.1.modelAnsweredUnlabelled > $0.1.modelAnswered / 2 })
            {
                print(
                    """

                      **Most of what the model answered has no label**, so the
                      delta above is measured on a small, unrepresentative
                      slice. The corpus labels a field only where the generator
                      put one in, which is largely where the rules already
                      read it. This is the same blindness that let dueAt read
                      97.9% while breaking on a real capture.
                    """)
            }
            print("")
        }

        print("  model calls made   \(b.modelCalls)")
        print(
            "  cassettes          \(cassettes.hits) hit · \(cassettes.misses) miss"
                + " · \(cassettes.recorded) recorded")
        if b.modelCalls == 0 {
            print(
                """

                  **No model call happened.** In replay a capability with no
                  cassette abstains, so the two paths are the same path and the
                  comparison says nothing yet. Record first:

                    export GOOGLE_AI_API_KEY=...
                    swift run brain record --capability classify-type   --escalations-only --limit 50
                    swift run brain record --capability estimate-effort --escalations-only --limit 300
                    swift run brain record --capability classify-category --escalations-only --limit 160

                """)
        }

        print(
            """
              Where each answer came from, in the hybrid path:
            """)
        for (name, score) in b.fields where !score.byTier.isEmpty {
            let parts = score.byTier.sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue)=\($0.value)" }
                .joined(separator: " ")
            print("    \(Printer.pad(name, 10)) \(parts)")
        }
        print("")
    }
}
