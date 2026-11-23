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

    @Option(name: .long, help: "Second model, to compare head to head on the same captures.")
    var against: String?

    @Option(name: .long, help: "Dataset split.")
    var split: String = "dev"

    @Option(name: .long, help: "Cassette directory.")
    var cassettes: String = "eval/cassettes"

    @Flag(name: .long, help: "Show every scored capture.")
    var verbose = false

    func run() async throws {
        if let against {
            try await compare(model, against)
            return
        }
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

    /// Head-to-head on identical captures, so the comparison is paired and
    /// does not depend on both models having recorded the same number.
    private func compare(_ a: String, _ b: String) async throws {
        let zone = TimeZone(identifier: "Asia/Kolkata")!
        let now = SyntheticLoader.now
        let captures = try SyntheticLoader.load(
            directory: URL(fileURLWithPath: "datasets/v1"), split: split)
        let classifier = TypeClassifier(timeZone: zone)
        let store = CassetteStore(directory: URL(fileURLWithPath: cassettes), mode: .replay)

        struct Tally {
            var scored = 0, correct = 0, abstained = 0, correctAccepted = 0
            var tokens = 0
            /// Reliability bins, for expected calibration error.
            var bins: [Int: (n: Int, correct: Int, confidence: Double)] = [:]
        }
        var tallies: [String: Tally] = [a: Tally(), b: Tally()]
        var paired = 0

        for capture in captures {
            guard let expected = capture.labels.type,
                !classifier.classify(capture.rawText, now: now).isKnown
            else { continue }
            let normalized = Normalizer.normalize(capture.rawText)
            let request = ModelRequest(
                capability: .classifyType, system: Prompts.classifyTypeSystem,
                untrustedContent: normalized.redacted,
                allowedAnswers: ItemType.allCases.map(\.rawValue),
                promptVersion: Prompts.version)

            // Only captures BOTH models answered, or the two columns would be
            // measured on different data and the comparison would be noise.
            guard let first = await store.lookup(request, model: a),
                let second = await store.lookup(request, model: b)
            else { continue }
            paired += 1

            for (name, response) in [(a, first), (b, second)] {
                var tally = tallies[name]!
                tally.scored += 1
                tally.tokens += response.promptTokens + response.completionTokens
                let answer = Guards.schema(
                    raw: response.raw, allowed: request.allowedAnswers
                ).accepted
                let isCorrect = answer == expected
                if isCorrect { tally.correct += 1 }

                // Illustrative, NOT the shipping operating point. B4 measured
                // the sweep (`brain guard-eval`): at 0.7 this discards 7 of 24
                // correct answers and catches no error. The live default is
                // `Rung.acceptAbove = 0`. Kept at 0.7 here only so the column
                // stays comparable with earlier runs.
                if response.confidence >= 0.7 {
                    if isCorrect { tally.correctAccepted += 1 }
                } else {
                    tally.abstained += 1
                }

                let bin = min(9, Int(response.confidence * 10))
                var entry = tally.bins[bin] ?? (0, 0, 0)
                entry.n += 1
                entry.correct += isCorrect ? 1 : 0
                entry.confidence += response.confidence
                tally.bins[bin] = entry
                tallies[name] = tally
            }
        }

        guard paired > 0 else {
            print("\nNo captures recorded by both \(a) and \(b).")
            return
        }

        /// Expected calibration error: the gap between stated confidence and
        /// actual accuracy, weighted by bin size.
        func ece(_ tally: Tally) -> Double {
            let n = Double(tally.scored)
            return tally.bins.values.reduce(0.0) { sum, bin in
                let accuracy = Double(bin.correct) / Double(bin.n)
                let meanConfidence = bin.confidence / Double(bin.n)
                return sum + Double(bin.n) / n * abs(accuracy - meanConfidence)
            }
        }

        print(
            """

            TWO-TRACK COMPARISON  (split \(split), \(paired) captures both models answered)

            These are the captures T0 abstained on, where T0 scores 0% by
            construction. Identical captures in both columns.

            """)
        // Manual padding: String(format:) with %@ does not honour a width
        // specifier here, so the columns came out unaligned.
        func pad(_ text: String, _ width: Int) -> String {
            text.count >= width
                ? String(text.prefix(width))
                : text + String(repeating: " ", count: width - text.count)
        }
        print("  \(pad("", 26))\(pad(a, 22))\(pad(b, 22))")

        func row(_ label: String, _ format: (Tally) -> String) {
            print(
                "  \(pad(label, 26))\(pad(format(tallies[a]!), 22))"
                    + pad(format(tallies[b]!), 22))
        }
        row("accuracy") {
            String(format: "%.1f%%", 100 * Double($0.correct) / Double(max($0.scored, 1)))
        }
        row("accepted at conf >= 0.7") { "\($0.scored - $0.abstained)/\($0.scored)" }
        row("…and correct") { "\($0.correctAccepted)" }
        row("mean tokens/call") { "\($0.tokens / max($0.scored, 1))" }
        row("ECE (lower is better)") { String(format: "%.3f", ece($0)) }
        row("mean confidence") {
            let total = $0.bins.values.reduce(0.0) { $0 + $1.confidence }
            return String(format: "%.2f", total / Double(max($0.scored, 1)))
        }
        row("distinct confidences") { "\($0.bins.count)" }

        // ECE on its own is a trap here, and reading it naively would have
        // led to the wrong conclusion. Say so in the output.
        let aBins = tallies[a]!.bins.count
        let bBins = tallies[b]!.bins.count
        print(
            """

            Reading this honestly
            ---------------------
            ECE is the gap between stated confidence and actual accuracy, and
            on its own it is misleading here.

            A model that answers 1.0 to everything and is 94% right scores a
            low ECE — but its confidence carries **no information**, so no
            threshold can separate its good answers from its bad ones. Look at
            "distinct confidences": \(a) has \(aBins), \(b) has \(bBins).

            A model with a genuine distribution can still be badly calibrated
            by being systematically under-confident, which costs correct
            answers at a fixed threshold rather than letting wrong ones
            through. That is a fixable problem — temperature scaling and a
            fitted threshold are exactly what B5 is for. A constant confidence
            is not fixable at all.
            """)
    }
}
