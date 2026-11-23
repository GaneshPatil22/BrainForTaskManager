import BrainCore
import Foundation

/// Record each model call once, then replay it forever: offline, deterministic
/// and free.
///
/// This is what makes the eval runnable at all. Gemma 4 allows 14,400 requests
/// a day across the whole project; a single eval sweep over 2,000 synthetic
/// captures would eat an eighth of that, and a regression gate that costs
/// quota every time it runs will be switched off.
public enum CassetteMode: String, Sendable, CaseIterable {
    /// Default everywhere. A miss is a **hard error**, never a silent live
    /// call — otherwise a cassette gap turns an offline run into a surprise
    /// bill and a non-deterministic result.
    case replay
    /// Call live and write the recording. Still honours every budget.
    case record
    /// Live, no recording. Development only.
    case live
}

/// A recorded call. Stores the prompt version and the inputs that produced it,
/// so a recording made under an older prompt is a miss rather than a wrong hit.
public struct Cassette: Codable, Sendable {
    public let key: String
    public let capability: String
    public let promptVersion: String
    public let model: String
    public let answer: String?
    public let confidence: Double
    public let promptTokens: Int
    public let completionTokens: Int
    public let raw: String
    public let recordedAt: String

    public var response: ModelResponse {
        ModelResponse(
            answer: answer, confidence: confidence, promptTokens: promptTokens,
            completionTokens: completionTokens, raw: raw)
    }
}

/// File-backed cassette store, one JSON file per recording.
///
/// One file each rather than a single archive, so recordings merge in git
/// without conflicts and a stale one can be deleted by hand.
public actor CassetteStore {
    private let directory: URL
    private let mode: CassetteMode
    private var memory: [String: Cassette] = [:]
    private var loaded = false

    public private(set) var hits = 0
    public private(set) var misses = 0
    public private(set) var recorded = 0

    public init(directory: URL, mode: CassetteMode) {
        self.directory = directory
        self.mode = mode
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                let cassette = try? decoder.decode(Cassette.self, from: data)
            else { continue }
            memory[cassette.key] = cassette
        }
    }

    /// Returns the recorded response, or throws `.cassetteMiss` in replay mode.
    public func replay(_ request: ModelRequest) throws -> ModelResponse {
        loadIfNeeded()
        guard let cassette = memory[request.cacheKey] else {
            misses += 1
            throw ProviderError.cassetteMiss(key: request.cacheKey)
        }
        hits += 1
        return cassette.response
    }

    public func lookup(_ request: ModelRequest) -> ModelResponse? {
        loadIfNeeded()
        if let cassette = memory[request.cacheKey] {
            hits += 1
            return cassette.response
        }
        misses += 1
        return nil
    }

    public func write(
        _ request: ModelRequest, response: ModelResponse, model: String
    ) throws {
        guard mode == .record else { return }
        loadIfNeeded()
        let cassette = Cassette(
            key: request.cacheKey, capability: request.capability.rawValue,
            promptVersion: request.promptVersion, model: model,
            answer: response.answer, confidence: response.confidence,
            promptTokens: response.promptTokens, completionTokens: response.completionTokens,
            raw: response.raw,
            recordedAt: ISO8601DateFormatter().string(from: Date()))
        memory[cassette.key] = cassette
        recorded += 1

        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(cassette)
            .write(to: directory.appendingPathComponent("\(cassette.key).json"))
    }

    public func stats() -> (hits: Int, misses: Int, recorded: Int) {
        (hits, misses, recorded)
    }
}

/// A provider that answers from a fixed rule, with no network and no model.
///
/// For unit tests, and for exercising the pipeline end to end before any key
/// exists. Deterministic by construction: the same request always produces the
/// same answer, so a test that fails did so because of our code.
public struct FakeModel: LLMProvider {
    public let id = ProviderID("fake")
    /// Decides the answer. Defaults to "always the first allowed value".
    private let behaviour: @Sendable (ModelRequest) -> ModelResponse

    public init(behaviour: @escaping @Sendable (ModelRequest) -> ModelResponse) {
        self.behaviour = behaviour
    }

    /// Always picks the first permitted answer.
    public static func firstAllowed(confidence: Double = 0.9) -> FakeModel {
        FakeModel { request in
            ModelResponse(
                answer: request.allowedAnswers.first, confidence: confidence,
                promptTokens: estimateTokenCount(request.system + request.untrustedContent),
                completionTokens: 2, raw: request.allowedAnswers.first ?? "")
        }
    }

    /// Always abstains. Used to prove the pipeline degrades rather than breaks.
    public static func alwaysAbstains() -> FakeModel {
        FakeModel { _ in .abstained }
    }

    /// Answers with something outside the permitted set, to prove guard 1 and
    /// guard 3 actually catch it rather than being decorative.
    public static func misbehaves(with answer: String = "item-99999") -> FakeModel {
        FakeModel { _ in
            ModelResponse(
                answer: answer, confidence: 0.99, promptTokens: 10,
                completionTokens: 2, raw: answer)
        }
    }

    /// Fails every call, for exercising the circuit breaker and the fallback
    /// ladder.
    public static func alwaysFails(_ error: ProviderError = .transport("fake failure"))
        -> FailingModel
    {
        FailingModel(error: error)
    }

    public func complete(_ request: ModelRequest) async throws -> ModelResponse {
        behaviour(request)
    }

    public func estimateTokens(_ request: ModelRequest) -> Int {
        estimateTokenCount(request.system + request.untrustedContent)
    }
}

public struct FailingModel: LLMProvider {
    public let id = ProviderID("failing")
    let error: ProviderError

    public func complete(_ request: ModelRequest) async throws -> ModelResponse {
        throw error
    }
    public func estimateTokens(_ request: ModelRequest) -> Int { 10 }
}
