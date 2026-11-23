import ArgumentParser
import BrainAdapters
import BrainCore
import BrainDatasets
import BrainHarness
import BrainPipeline
import Foundation

/// Scores the model's answers against the labels, on the only captures where a
/// model call would ever happen: the ones T0 abstained on.
///
/// **On that set T0 scores 0% by construction** — it produced nothing. So any
/// T2 accuracy above zero is a genuine gain, and the question is how large it
/// is and what it costs. Measuring T2 over the whole dataset instead would
/// flatter it with 390 captures the rules already handle for free.
///
/// Replay only. This command never spends quota.
struct T2ScoreCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "t2-score",
        abstract: "Score recorded model answers against labels, on the escalation set.")

    @Option(name: .long, help: "Model whose cassettes to score.")
    var model: String = "gemma-4-26b-a4b-it"

    @Option(name: .long, help: "Dataset split.")
    var split: String = "dev"

    @Option(name: .long, help: "Cassette directory.")
    var cassettes: String = "eval/cassettes"

    @Flag(name: .long, help: "Show every scored capture.")
    var verbose = false

    func run() async throws {
        let zone = TimeZone(identifier: "Asia/Kolkata")!
        let now = SyntheticLoader.now
        let captures = try SyntheticLoader.load(
            directory: URL(fileURLWithPath: "datasets/v1"), split: split)
        let classifier = TypeClassifier(timeZone: zone)

        let escalations = captures.filter {
            !classifier.classify($0.rawText, now: now).isKnown && $0.labels.type != nil
        }
        let store = CassetteStore(
            directory: URL(fileURLWithPath: cassettes), mode: .replay)

        var scored = 0, correct = 0, missing = 0, rejectedByGuards = 0
        var tokens = 0
        var rows: [(String, String, String)] = []

        for capture in escalations {
            guard let expected = capture.labels.type else { continue }
            let normalized = Normalizer.normalize(capture.rawText)
            let request = ModelRequest(
                capability: .classifyType, system: Prompts.classifyTypeSystem,
                untrustedContent: normalized.redacted,
                allowedAnswers: ItemType.allCases.map(\.rawValue),
                promptVersion: Prompts.version)

            guard let response = await store.lookup(request, model: model) else {
                missing += 1
                continue
            }
            tokens += response.promptTokens + response.completionTokens

            // Score what the pipeline would actually accept, guards included —
            // not the raw string. A model answer the guards reject is not an
            // answer the product would ever have used.
            let outcome = Guards.schema(
                raw: response.raw, allowed: request.allowedAnswers)
            guard let answer = outcome.accepted else {
                rejectedByGuards += 1
                scored += 1
                rows.append((capture.rawText, expected, "(rejected)"))
                continue
            }
            scored += 1
            if answer == expected { correct += 1 }
            rows.append((capture.rawText, expected, answer))
        }

        guard scored > 0 else {
            print(
                """

                No cassettes for \(model) on split \(split).
                Record some first:  swift run brain record --limit 30 --escalations-only
                """)
            return
        }

        let accuracy = Double(correct) / Double(scored)
        let interval = 1.96 * (accuracy * (1 - accuracy) / Double(scored)).squareRoot()
        print(
            """

            T2 ON THE ESCALATION SET  (\(model), split \(split))

              captures T0 could not type   \(escalations.count)
              of those, recorded           \(scored)
              not recorded yet             \(missing)

              T0 accuracy on this set       0.0%   (it abstained, by definition)
              T2 accuracy on this set     \(String(format: "%5.1f%%", accuracy * 100))   \
            ±\(String(format: "%.0f", interval * 100))pp at 95%
              rejected by guards          \(rejectedByGuards)

              tokens spent                 \(tokens)  (mean \(tokens / scored)/call)

            """)

        if scored < 30 {
            print(
                """
                  \(scored) scored calls is far too few to decide anything. The
                  interval above is wider than the effect we are looking for.
                  Treat this as "the wiring works", not "the model is good".

                """)
        }
        if verbose {
            for (text, expected, got) in rows.prefix(30) {
                let mark = expected == got ? " " : "✗"
                print(
                    "  \(mark) want \(expected.padding(toLength: 9, withPad: " ", startingAt: 0)) "
                        + "got \(got.padding(toLength: 11, withPad: " ", startingAt: 0)) \(text.prefix(52))"
                )
            }
        }
    }
}
