import ArgumentParser
import BrainCore
import BrainDatasets
import Foundation

/// Measures the T0 category lexicon against labelled titles.
///
/// This exists because `docs/09-tiering.md` requires a **measured** number
/// before any rule is trusted, and a measured number before any model call is
/// allowed to replace it. "The lexicon looks about right" is not an argument.
struct CategoryEvalCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "category-eval",
        abstract: "Measure the T0 category classifier against labelled titles.")

    @Option(name: .long, help: "JSON map of title -> category.")
    var truth: String = "/tmp/category-truth.json"

    @Flag(name: .long, help: "List the misclassified titles.")
    var showErrors = false

    @Flag(name: .long, help: "Sweep the abstention margin and print the curve.")
    var sweep = false

    @Option(name: .long, help: "Abstention margin to evaluate at.")
    var minMargin: Double?

    func run() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: truth))
        let labels = try JSONDecoder().decode([String: String].self, from: data)

        if sweep {
            print("\n  margin   coverage   acc@attempted   acc@all   wrong")
            for step in stride(from: 0.0, through: 0.75, by: 0.05) {
                var ok = 0, bad = 0
                for (title, expected) in labels {
                    guard let v = CategoryClassifier.classify(title, minMargin: step).value
                    else { continue }
                    if v.rawValue == expected { ok += 1 } else { bad += 1 }
                }
                let att = ok + bad, n = labels.count
                print(
                    String(
                        format: "  %5.2f    %5.1f%%        %5.1f%%     %5.1f%%    %4d",
                        step, 100 * Double(att) / Double(n),
                        att == 0 ? 0 : 100 * Double(ok) / Double(att),
                        100 * Double(ok) / Double(n), bad))
            }
            print(
                """

                  Pick the knee: the point past which extra coverage costs more
                  wrong answers than it gains right ones. A wrong T0 answer is
                  worse than an abstention, because it never escalates.
                """)
            return
        }

        var correct = 0, wrong = 0, abstained = 0
        var confusion: [String: [String: Int]] = [:]
        var errors: [(String, String, String)] = []

        for (title, expected) in labels.sorted(by: { $0.key < $1.key }) {
            let predicted = CategoryClassifier.classify(
                title, minMargin: minMargin ?? CategoryClassifier.defaultMinMargin)
            guard let value = predicted.value else {
                abstained += 1
                confusion[expected, default: [:]]["(abstained)", default: 0] += 1
                continue
            }
            if value.rawValue == expected {
                correct += 1
            } else {
                wrong += 1
                errors.append((title, expected, value.rawValue))
            }
            confusion[expected, default: [:]][value.rawValue, default: 0] += 1
        }

        let attempted = correct + wrong
        let total = labels.count
        func pct(_ a: Int, _ b: Int) -> String {
            b == 0 ? "n/a" : String(format: "%.1f%%", 100 * Double(a) / Double(b))
        }

        print(
            """

            T0 CATEGORY LEXICON  (\(total) labelled titles)

              accuracy on attempted   \(pct(correct, attempted))   (\(correct)/\(attempted))
              coverage (not abstained) \(pct(attempted, total))   (\(attempted)/\(total))
              accuracy over all        \(pct(correct, total))

            Per category (recall):
            """)
        for category in TaskCategory.allCases {
            let row = confusion[category.rawValue] ?? [:]
            let n = row.values.reduce(0, +)
            guard n > 0 else { continue }
            let hit = row[category.rawValue] ?? 0
            let abst = row["(abstained)"] ?? 0
            print(
                String(
                    format: "  %-14@ %5@  (n=%d, abstained %d)",
                    category.rawValue as NSString,
                    pct(hit, n) as NSString, n, abst))
        }

        if showErrors {
            print("\nMisclassified (\(errors.count)):")
            for (title, expected, got) in errors.prefix(60) {
                print("  \(title)\n      expected \(expected), got \(got)")
            }
        }

        print(
            """

            Abstention is a legitimate outcome: a tie between two categories is
            real ambiguity, and docs/04-scorecard.md rewards abstaining over a
            wrong guess. Read coverage and accuracy together — neither alone.
            """)
    }
}
