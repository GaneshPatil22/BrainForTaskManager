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
        let router = await ProductionRouter.make(
            apiKey: key, ledger: BudgetLedger(), cassettes: store,
            mode: live ? .live : .replay)

        let now = SyntheticLoader.now
        let rules = await Metrics.comparePath(
            name: "rules only", captures: captures,
            pipeline: EnrichmentPipeline(timeZone: zone), timeZone: zone, now: now)
        let flags = try parsedFeatures()
        let hybrid = await Metrics.comparePath(
            name: "rules + model", captures: captures,
            pipeline: EnrichmentPipeline(timeZone: zone, router: router, features: flags),
            timeZone: zone, now: now)

        Self.render(
            rules, hybrid, split: split, live: live,
            features: features.isEmpty ? "none" : features)
    }

    static func render(
        _ a: Metrics.PathResult, _ b: Metrics.PathResult, split: String, live: Bool,
        features: String
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

        print("  model calls made   \(b.modelCalls)")
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
