import BrainCore
import Foundation

/// A synthetic capture whose labels are true **by construction**: the text was
/// composed from a known date phrase, duration, verb and object
/// (`scripts/make-synthetic.py`).
///
/// That is the whole point. Judged labels on generated text measure whether we
/// reimplemented the generator — see `docs/13-generated-datasets.md`.
public struct SyntheticCapture: Codable, Sendable {
    public struct Labels: Codable, Sendable {
        public let type: String?
        public let effort: String?
        /// Day offset from the fixed "now", not an absolute date.
        public let dueAt: Int?
        public let category: String?
        public let dependency: String?
    }

    public let id: String
    public let rawText: String
    public let source: String
    public let userTz: String
    public let labels: Labels
    /// UTF-16 spans for the parts that carry a label. Empty when a typo was
    /// injected, because the offsets are no longer trustworthy.
    public let spans: [String: [Int]]
    public let labelSource: String
}

public enum SyntheticLoader {
    /// The fixed clock every dataset label is relative to.
    ///
    /// **Monday 23 Nov 2026, 09:00 IST.** Defined once and imported everywhere,
    /// because it was briefly three separate literals and one of them was wrong
    /// — Wednesday 18 Nov — which silently mis-scored every weekday-relative
    /// date in the eval. A wrong clock in the harness is worse than a wrong
    /// parser: it makes correct code look broken.
    public static let now = Date(timeIntervalSince1970: 1_795_404_600)

    public static func load(directory: URL, split: String) throws -> [SyntheticCapture] {
        let path =
            directory
            .appendingPathComponent(split)
            .appendingPathComponent("synthetic.jsonl")
        guard let raw = try? String(contentsOf: path, encoding: .utf8) else { return [] }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var rows: [SyntheticCapture] = []
        for (index, line) in raw.components(separatedBy: .newlines).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            do {
                rows.append(try decoder.decode(SyntheticCapture.self, from: Data(trimmed.utf8)))
            } catch {
                throw DatasetError("\(split)/synthetic.jsonl line \(index + 1): \(error)")
            }
        }
        return rows
    }
}
