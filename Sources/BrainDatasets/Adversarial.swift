import BrainCore
import Foundation

/// One adversarial capture and what the T0 parsers should do with it.
///
/// A `nil` expectation means **must abstain** — a real expectation, not missing
/// data. `docs/04-scorecard.md` rewards abstaining over a wrong guess, so
/// "returns nothing" is the assertion.
public struct AdversarialCase: Codable, Sendable {
    public struct Expectation: Codable, Sendable {
        /// Day offset from `now` ("+1", "-2"), or nil to require abstention.
        public let date: String?
        /// Effort bucket raw value, or nil to require abstention.
        public let effort: String?
        /// Category raw value, or nil to require abstention.
        public let category: String?
        /// Referent text of the first dependency, or nil to require none.
        public let dependency: String?
        public let maxLatencyMs: Double

        public init(
            date: String?, effort: String?, category: String?,
            dependency: String?, maxLatencyMs: Double
        ) {
            self.date = date
            self.effort = effort
            self.category = category
            self.dependency = dependency
            self.maxLatencyMs = maxLatencyMs
        }
    }

    public let id: String
    public let attack: String
    public let rawText: String
    public let source: String
    public let expect: Expectation
    /// The phase at which this row can actually be scored. Injection rows say
    /// `B3`: with no model in the loop there is nothing to be non-compliant,
    /// and scoring them now would be theatre.
    public let evaluatedAt: String
    public let note: String

    public init(
        id: String, attack: String, rawText: String, source: String,
        expect: Expectation, evaluatedAt: String, note: String
    ) {
        self.id = id
        self.attack = attack
        self.rawText = rawText
        self.source = source
        self.expect = expect
        self.evaluatedAt = evaluatedAt
        self.note = note
    }
}

public enum AdversarialLoader {

    public static func load(directory: URL) throws -> [AdversarialCase] {
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        var cases: [AdversarialCase] = []
        for url in files.filter({ $0.pathExtension == "jsonl" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        {
            let raw = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in raw.components(separatedBy: .newlines).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                do {
                    cases.append(
                        try decoder.decode(AdversarialCase.self, from: Data(trimmed.utf8)))
                } catch {
                    throw DatasetError(
                        "\(url.lastPathComponent) line \(index + 1): \(error)")
                }
            }
        }
        return cases
    }
}
