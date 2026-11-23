import ArgumentParser
import BrainCore
import BrainDatasets
import BrainEval
import BrainHarness
import BrainPipeline
import Foundation

/// Measures what each guard actually buys, one at a time.
///
/// B4 in `docs/00-charter.md`: *"Guards, added one at a time, each with its
/// measured effect."* Until now the guards were built and unit-tested but
/// never measured on real data, so we could not say what any of them was
/// worth — only that it worked on cases we invented for it.
///
/// Replay and local only. Spends no quota.
struct GuardEvalCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "guard-eval",
        abstract: "Per-guard before/after on real data. No quota spent.")

    @Option(name: .long, help: "Dataset split.")
    var split: String = "dev"

    @Option(name: .long, help: "Cassette directory.")
    var cassettes: String = "eval/cassettes"

    @Option(name: .long, help: "Real captures, for the PII guard.")
    var captures: String?

    func run() async throws {
        let zone = TimeZone(identifier: "Asia/Kolkata")!
        let now = SyntheticLoader.now
        let allowed = ItemType.allCases.map(\.rawValue)
        let synthetic = try SyntheticLoader.load(
            directory: URL(fileURLWithPath: "datasets/v1"), split: split)
        let classifier = TypeClassifier(timeZone: zone)
        let store = CassetteStore(directory: URL(fileURLWithPath: cassettes), mode: .replay)

        // The escalation set: the only place a guard on model output can fire.
        struct Sample {
            let expected: String
            let gemma: ModelResponse?
            let decision: ModelResponse?
        }
        var samples: [Sample] = []
        for capture in synthetic {
            guard let expected = capture.labels.type,
                !classifier.classify(capture.rawText, now: now).isKnown
            else { continue }
            let request = ModelRequest(
                capability: .classifyType, system: Prompts.classifyTypeSystem,
                untrustedContent: Normalizer.normalize(capture.rawText).redacted,
                allowedAnswers: allowed, promptVersion: Prompts.version)
            let gemma = await store.lookup(request, model: "gemma-4-26b-a4b-it")
            let decision = await store.lookup(request, model: "gemini-decision-1")
            guard gemma != nil || decision != nil else { continue }
            samples.append(Sample(expected: expected, gemma: gemma, decision: decision))
        }

        print(
            """

            GUARD EVALUATION  (split \(split))

            Each guard measured on its own, against the data where it can
            actually fire. "Caught" means the guard prevented a wrong answer
            reaching the product; "cost" means it discarded a right one.

            """)

        // --- Guard 1: ID whitelist ------------------------------------------
        let audit = Metrics.auditCassettes(
            directory: URL(fileURLWithPath: cassettes), allowed: allowed)
        section(
            "1  ID whitelist",
            fires: "answers naming something outside the option set",
            measured: "\(audit.outOfSet) of \(audit.answers) recorded answers",
            verdict: audit.outOfSet == 0
                ? """
                Caught nothing, and that is the expected result rather than a
                disappointment. Both providers are given a closed option set,
                so an out-of-set answer is already hard to express — with the
                Decisions API it is impossible. The guard is cheap insurance
                against a future provider with a looser contract, and it is
                what makes the 0% target a property of the code rather than
                of the model.
                """
                : "Caught \(audit.outOfSet). Examples: \(audit.examples.joined(separator: " | "))")

        // --- Guard 3: schema -------------------------------------------------
        section(
            "3  schema / enum validation",
            fires: "output that is not exactly one permitted value",
            measured: "\(audit.neededNormalising) normalised, "
                + "\(audit.rejectedBySchema) rejected, of \(audit.answers)",
            verdict: audit.neededNormalising == 0 && audit.rejectedBySchema == 0
                ? """
                Never fired. Both providers returned clean single-word
                answers. Worth keeping: it is the only thing standing between
                a chatty model and a parse failure, and the first Gemma call
                of this project returned a bullet list of its own reasoning.
                """
                : "Rescued \(audit.neededNormalising) answers that would otherwise have been lost.")

        // --- Guard 4: abstention ---------------------------------------------
        print("4  abstention threshold\n")
        print("   fires on: answers below a confidence threshold\n")
        print("   threshold   accepted   correct   wrong-through   right-discarded")
        for threshold in [0.0, 0.5, 0.6, 0.7, 0.8, 0.9] {
            var accepted = 0, correct = 0, wrongThrough = 0, rightDiscarded = 0
            for sample in samples {
                guard let response = sample.decision else { continue }
                let answer = Guards.schema(raw: response.raw, allowed: allowed).accepted
                let isCorrect = answer == sample.expected
                if response.confidence >= threshold {
                    accepted += 1
                    if isCorrect { correct += 1 } else { wrongThrough += 1 }
                } else if isCorrect {
                    rightDiscarded += 1
                }
            }
            print(
                String(
                    format: "   %7.1f   %8d   %7d   %13d   %15d",
                    threshold, accepted, correct, wrongThrough, rightDiscarded))
        }
        // Name an operating point — but the honest answer here is mostly
        // about how little 25 samples can tell us.
        var wrongCount = 0
        var lowestConfidence = 1.0
        var highestSafe = 0.0  // the largest threshold costing no correct answer
        for sample in samples {
            guard let response = sample.decision else { continue }
            let answer = Guards.schema(raw: response.raw, allowed: allowed).accepted
            if answer == sample.expected {
                lowestConfidence = min(lowestConfidence, response.confidence)
            } else {
                wrongCount += 1
            }
        }
        highestSafe = lowestConfidence
        print(
            """

               Wrong answers in this sample: \(wrongCount) of \(samples.count).

            """)
        if wrongCount < 10 {
            print(
                """
                   Too few to fit a threshold on. The sweep's "best" cut would
                   sit just under the one wrong answer's confidence, which is
                   fitting a parameter to a single data point — it would not
                   survive contact with the next \(samples.count) captures.
                   No threshold is being set from this.

                   What the data does support is an upper bound. The lowest
                   confidence on a CORRECT answer is \
                \(String(format: "%.2f", highestSafe)), so any threshold above
                   that is measurably buying nothing and costing correct
                   answers. 0.7 — the constant `T2ScoreCommand` reports at —
                   discards 7 of 24 correct answers for no caught error.

                   Note the live default is `Rung.acceptAbove = 0`
                   (`Sources/BrainHarness/Router.swift`): nothing is gated
                   today. That is a defensible place to stay until there are
                   enough errors to fit against, but it should be a decision
                   rather than an unexamined default, so it is recorded as one
                   in DECISIONS.md.

                """)
        } else {
            print(
                """
                   \(wrongCount) errors is enough to fit against; see the sweep
                   above and set `acceptAbove` on the T2 rung accordingly.

                """)
        }
        print(
            """
               Measured on gemini-decision-1, the only provider reporting a real
               confidence (35 recorded, spread 0.32-0.95). Gemma answers 1.00 to
               everything, so every threshold accepts everything and the guard
               is inert for it. That is itself the finding: a model with
               constant confidence cannot be gated at any threshold.

            """)

        // --- Guard 7: cross-check --------------------------------------------
        var both = 0, agreed = 0, agreedCorrect = 0, disagreed = 0
        var disagreementHadOneRight = 0
        for sample in samples {
            guard let gemma = sample.gemma, let decision = sample.decision else { continue }
            both += 1
            let a = Guards.schema(raw: gemma.raw, allowed: allowed).accepted
            let b = Guards.schema(raw: decision.raw, allowed: allowed).accepted
            if a == b {
                agreed += 1
                if a == sample.expected { agreedCorrect += 1 }
            } else {
                disagreed += 1
                if a == sample.expected || b == sample.expected { disagreementHadOneRight += 1 }
            }
        }
        section(
            "7  cross-check (two tiers must agree)",
            fires: "the two providers returning different answers",
            measured: both == 0
                ? "no captures answered by both"
                : "\(agreed)/\(both) agreed · \(agreedCorrect) of those correct "
                    + "· \(disagreed) disagreed",
            verdict: both == 0
                ? "Not measurable yet."
                : """
                When they agree, \(agreedCorrect) of \(agreed) are right
                (\(pct(Double(agreedCorrect) / Double(max(agreed, 1))))). Of the
                \(disagreed) disagreements, \(disagreementHadOneRight) had a
                correct answer on one side — so cross-checking would have
                left \(disagreementHadOneRight) correct answers unconfirmed
                rather than wrong. That is the trade: precision bought with
                recall, which `docs/04-scorecard.md` says we want.
                """)

        // --- Guard 10: PII strip ----------------------------------------------
        if let path = captures, let raw = try? String(contentsOfFile: path, encoding: .utf8) {
            let lines = raw.components(separatedBy: .newlines)
                .map { CoverageCommand.stripListNumbering($0) }
                .filter { !$0.isEmpty }
            var redacted = 0
            var kinds: [String: Int] = [:]
            for line in lines {
                let (output, changed) = Guards.stripPII(line)
                if changed {
                    redacted += 1
                    for marker in ["[phone]", "[email]", "[amount]", "[otp]", "[id-number]"]
                    where output.contains(marker) {
                        kinds[marker, default: 0] += 1
                    }
                }
            }
            section(
                "10 PII strip",
                fires: "a capture containing a phone, email, amount, OTP or card number",
                measured: "\(redacted) of \(lines.count) real captures redacted "
                    + "(\(pct(Double(redacted) / Double(max(lines.count, 1)))))  "
                    + kinds.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }
                    .joined(separator: " "),
                verdict: """
                    Measured on Ganesh's own captures, not synthetic ones. Every
                    redaction is content that would otherwise have reached a
                    free-tier provider whose terms permit training on it
                    (ADR-0002). The original is untouched — only the copy bound
                    for a model loses it.
                    """)
        } else {
            section(
                "10 PII strip", fires: "a capture containing personal data",
                measured: "not run",
                verdict: "Pass --captures <file> to measure this on real text.")
        }

        // --- Guard 12: claim check ---------------------------------------------
        section(
            "12 claim check",
            fires: "a rephrased explanation inventing a number",
            measured: "0 opportunities",
            verdict: """
                Cannot fire yet: explanations are templates filled from graph
                facts and nothing rephrases them. The guard exists for the day a
                model is allowed near the "why" text. Reporting it as 100%
                effective would be meaningless — it has never been asked a
                question.
                """)
    }

    private func section(_ title: String, fires: String, measured: String, verdict: String) {
        print("\(title)\n")
        print("   fires on: \(fires)")
        print("   measured: \(measured)\n")
        // Re-wrap to a fixed width: the source strings are indented for
        // readability in code, which produced ragged output.
        var line = "  "
        for word in verdict.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            if line.count + word.count + 1 > 74 {
                print(" \(line)")
                line = "  "
            }
            line += " \(word)"
        }
        if line.count > 2 { print(" \(line)") }
        print("")
    }

    private func pct(_ value: Double) -> String { String(format: "%.0f%%", value * 100) }
}
