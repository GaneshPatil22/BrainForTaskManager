import ArgumentParser
import BrainCore
import BrainDatasets
import Foundation

/// Turns a raw text dump into `datasets/real/captures.jsonl`.
///
/// Input is deliberately the loosest possible format — one capture per line —
/// because real captures come from wherever they come from: notes apps,
/// messages to yourself, scraps of paper. Anything that forces structure at
/// collection time changes what gets collected, which is exactly the bias we
/// are trying to avoid.
///
/// Output never enters git (`datasets/real/` is gitignored).
struct IngestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ingest",
        abstract: "Turn a raw text dump of captures into the dataset format.")

    @Argument(help: "Text file, one capture per line.")
    var file: String

    @Option(name: .long, help: "Where to write the JSONL.")
    var out: String = "datasets/real/captures.jsonl"

    @Option(name: .long, help: "IANA timezone these were captured in.")
    var timezone: String = "Asia/Kolkata"

    func run() throws {
        let raw = try String(contentsOfFile: file, encoding: .utf8)
        var seen = Set<String>()
        var rows: [String] = []
        var counts = (train: 0, dev: 0, test: 0)
        var duplicates = 0
        var tooLong = 0

        for line in raw.components(separatedBy: .newlines) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !text.hasPrefix("#") else { continue }
            // Ids derive from content, so re-running ingest is idempotent and
            // a capture keeps its split forever.
            let id = ULID.derived(from: text)
            guard seen.insert(id.rawValue).inserted else { duplicates += 1; continue }
            if text.count > 2000 { tooLong += 1 }

            let split = DatasetSplit.forReal(id: id.rawValue).rawValue
            switch split {
            case "train": counts.train += 1
            case "dev": counts.dev += 1
            default: counts.test += 1
            }

            let row: [String: Any] = [
                "id": id.rawValue,
                "raw_text": text,
                "source": "text",
                "created_at": ISO8601DateFormatter().string(from: Date()),
                "user_tz": timezone,
                "split": split,
                "labels": NSNull(),  // filled in later; see docs/03
                "label_source": "unlabelled",
            ]
            let data = try JSONSerialization.data(
                withJSONObject: row,
                options: [.sortedKeys, .withoutEscapingSlashes])
            rows.append(String(decoding: data, as: UTF8.self))
        }

        let outURL = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(
            at: outURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try (rows.joined(separator: "\n") + "\n").write(
            to: outURL, atomically: true,
            encoding: .utf8)

        print(
            """
            Ingested \(rows.count) captures → \(out)

              train \(counts.train)   dev \(counts.dev)   test \(counts.test)
            """)
        if duplicates > 0 {
            print("  \(duplicates) exact duplicate lines collapsed (kept one each)")
        }
        if tooLong > 0 {
            print("  \(tooLong) over 2000 chars — check these are really one capture")
        }

        // Honest about what this sample can and cannot show.
        if counts.test < 60 {
            print(
                """

                NOTE: only \(counts.test) test rows. A measured 90% here has a 95%
                interval of roughly ±\(Int((1.96 * (0.09 / Double(max(counts.test, 1))).squareRoot()) * 100)) points.
                300 captures total is the target (docs/05-targets.md).
                """)
        }
    }
}
