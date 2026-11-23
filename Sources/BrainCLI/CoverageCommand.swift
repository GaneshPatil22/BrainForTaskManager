import ArgumentParser
import BrainCore
import BrainDatasets
import Foundation

/// Reports what the T0 rules can and cannot read in a file of real captures.
///
/// This is **coverage, not accuracy**: without labels we cannot say whether a
/// parsed date is the right date, only that something was parsed. Coverage is
/// still the number that matters first — a field we never extract cannot be
/// wrong, it is simply absent, and the gap is invisible until real text
/// arrives.
struct CoverageCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "coverage",
        abstract: "What the T0 rules read from a file of real captures.")

    @Argument(help: "Text file, one capture per line.")
    var file: String

    @Option(name: .long, help: "IANA timezone.")
    var timezone: String = "Asia/Kolkata"

    @Flag(name: .long, help: "List captures where nothing at all was recognised.")
    var showMisses = false

    func run() throws {
        guard let zone = TimeZone(identifier: timezone) else {
            throw ValidationError("unknown timezone: \(timezone)")
        }
        let raw = try String(contentsOfFile: file, encoding: .utf8)
        let captures = raw.components(separatedBy: .newlines)
            .map { CoverageCommand.stripListNumbering($0) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !captures.isEmpty else { throw ValidationError("no captures in \(file)") }

        let now = Date()
        let dateParser = DateParser(timeZone: zone)
        let effortParser = EffortParser()
        let dependencyParser = DependencyParser(timeZone: zone)
        let typeClassifier = TypeClassifier(timeZone: zone)

        var dates = 0, efforts = 0, deps = 0, categories = 0
        var types: [String: Int] = [:]
        var nothing: [String] = []
        var typeByValue: [ItemType: Int] = [:]

        for capture in captures {
            let date = dateParser.parse(capture, now: now)
            let effort = effortParser.parse(capture)
            let dependency = dependencyParser.parse(capture, now: now).first
            let category = CategoryClassifier.classify(capture)
            let type = typeClassifier.classify(capture, now: now)

            if date != nil { dates += 1 }
            if effort != nil { efforts += 1 }
            if dependency != nil { deps += 1 }
            if category.isKnown { categories += 1 }
            types[type.value?.rawValue ?? "(abstained)", default: 0] += 1
            if let value = type.value { typeByValue[value, default: 0] += 1 }

            // "Nothing recognised" means no type and no category — the capture
            // would land in the inbox as an unclassified blob.
            if !type.isKnown && !category.isKnown { nothing.append(capture) }
        }

        let n = Double(captures.count)
        func pct(_ count: Int) -> String {
            String(format: "%5.1f%% (%d)", 100 * Double(count) / n, count)
        }

        print("""

            T0 COVERAGE ON REAL CAPTURES  (\(captures.count) lines, \(file))

            Coverage, not accuracy — without labels we can say a date was read,
            not that it was the right date.

              type recognised       \(pct(captures.count - (types["(abstained)"] ?? 0)))
              category recognised   \(pct(categories))
              date found            \(pct(dates))
              effort found          \(pct(efforts))
              dependency found      \(pct(deps))
              nothing recognised    \(pct(nothing.count))

            Type breakdown:
            """)
        for (name, count) in types.sorted(by: { $0.value > $1.value }) {
            print(String(format: "  %-14@ %@", name as NSString, pct(count) as NSString))
        }

        if showMisses, !nothing.isEmpty {
            print("\nCaptures where nothing was recognised (\(nothing.count)):\n")
            for capture in nothing.prefix(40) { print("  \(capture)") }
            if nothing.count > 40 { print("  … and \(nothing.count - 40) more") }
        }
    }

    /// Strips "1. " / "12) " list numbering. People number their lists; the
    /// number is formatting, not content, and leaving it in makes every line
    /// look like it contains a digit.
    static func stripListNumbering(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let match = DateParser.firstMatch(#"^\d{1,3}[.)]\s+"#, trimmed) else {
            return trimmed
        }
        let span = DateParser.span(match)
        let utf16 = Array(trimmed.utf16)
        return String(decoding: utf16[span.end...], as: UTF16.self)
            .trimmingCharacters(in: .whitespaces)
    }
}
