import BrainCore
import Foundation

/// What the pipeline asks for. Never a model — a **capability**.
///
/// The pipeline must not know which rung answered, or swapping Google for Groq
/// becomes a code change instead of a config edit (`docs/06-model-router.md`).
public enum Capability: String, Sendable, CaseIterable {
    /// Which of {task, idea, note, reminder, link} this capture is.
    case classifyType
    /// For each candidate: duplicate, blocks, relates, or none.
    case judgeLink
}

public struct ProviderID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// A request to a model. Carries the closed option set, because the whole
/// hallucination-prevention strategy depends on the answer being a *choice*
/// rather than free text.
public struct ModelRequest: Sendable, Hashable {
    public let capability: Capability
    /// Instructions. Static across calls so a provider can cache them.
    public let system: String
    /// **Untrusted.** The user's capture. Delimited, never interpolated into
    /// instructions (`docs/07-harness-spec.md`, guard 9).
    public let untrustedContent: String
    /// The only answers that will be accepted. An answer outside this set is
    /// rejected in code, which is what makes a hallucinated id impossible
    /// rather than merely unlikely (guard 1).
    public let allowedAnswers: [String]
    /// Prompt version, so a cassette recorded against an older prompt is a miss
    /// rather than a silently wrong hit.
    public let promptVersion: String

    public init(
        capability: Capability, system: String, untrustedContent: String,
        allowedAnswers: [String], promptVersion: String
    ) {
        self.capability = capability
        self.system = system
        self.untrustedContent = untrustedContent
        self.allowedAnswers = allowedAnswers
        self.promptVersion = promptVersion
    }

    /// Stable key for cassettes. Includes the prompt version and the option set,
    /// so changing either invalidates the recording instead of reusing it.
    public var cacheKey: String {
        var hasher = FNV1a()
        hasher.combine(capability.rawValue)
        hasher.combine(promptVersion)
        hasher.combine(system)
        hasher.combine(untrustedContent)
        for answer in allowedAnswers { hasher.combine(answer) }
        return String(format: "%016llx", hasher.value)
    }
}

public struct ModelResponse: Sendable, Hashable {
    /// The chosen answer, or nil when the model abstained. Abstention is always
    /// a legal outcome (guard 4).
    public let answer: String?
    /// The model's own confidence, where it reports one.
    public let confidence: Double
    public let promptTokens: Int
    public let completionTokens: Int
    /// Raw output, kept for tracing so a bad result is replayable.
    public let raw: String
    /// Full probability distribution over the permitted answers, where the
    /// provider reports one.
    ///
    /// Needed for calibration: ECE is a scorecard metric
    /// (`docs/04-scorecard.md`) and cannot be computed from a single
    /// confidence number after the fact. Empty for providers that generate
    /// text, which have no distribution to report.
    public let probabilities: [String: Double]

    public init(
        answer: String?, confidence: Double, promptTokens: Int,
        completionTokens: Int, raw: String, probabilities: [String: Double] = [:]
    ) {
        self.answer = answer
        self.confidence = min(max(confidence, 0), 1)
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.raw = raw
        self.probabilities = probabilities
    }

    public static let abstained = ModelResponse(
        answer: nil, confidence: 0, promptTokens: 0, completionTokens: 0, raw: "")
}

public enum ProviderError: Error, Equatable, CustomStringConvertible {
    case rateLimited(retryAfter: TimeInterval?)
    case transport(String)
    case malformedOutput(String)
    case budgetExhausted(String)
    case circuitOpen(ProviderID)
    case cassetteMiss(key: String)

    public var description: String {
        switch self {
        case .rateLimited(let after): "rate limited\(after.map { ", retry after \($0)s" } ?? "")"
        case .transport(let detail): "transport: \(detail)"
        case .malformedOutput(let detail): "malformed output: \(detail)"
        case .budgetExhausted(let detail): "budget exhausted: \(detail)"
        case .circuitOpen(let id): "circuit open for \(id)"
        case .cassetteMiss(let key): "cassette miss: \(key)"
        }
    }

    /// Whether trying the next rung could plausibly succeed.
    public var isRetryableElsewhere: Bool {
        switch self {
        case .cassetteMiss: false  // a miss is a hard error in replay mode
        default: true
        }
    }
}

public protocol LLMProvider: Sendable {
    var id: ProviderID { get }
    func complete(_ request: ModelRequest) async throws -> ModelResponse
    /// Estimated **before** dispatch, never after. TPM is the binding free-tier
    /// constraint (`docs/06-model-router.md`), and you cannot stay under a
    /// token budget you only measure once you have spent it.
    func estimateTokens(_ request: ModelRequest) -> Int
}

/// Rough token estimate. Deliberately pessimistic for Hinglish: romanised
/// Hindi fragments into more tokens than English, so a character-count divisor
/// tuned on English would under-count exactly the inputs we care about.
public func estimateTokenCount(_ text: String) -> Int {
    let characters = text.count
    let nonAscii = text.unicodeScalars.filter { !$0.isASCII }.count
    // ~3.2 chars/token rather than the usual 4, plus a surcharge for non-ASCII.
    return Int(Double(characters) / 3.2) + nonAscii + 8
}

/// FNV-1a with a SplitMix finalizer. Same construction as `DatasetSplit.hash`,
/// and for the same reason: raw FNV has weak avalanche on trailing bytes.
public struct FNV1a {
    public private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325
    public init() {}

    public mutating func combine(_ text: String) {
        for byte in Array(text.utf8) {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01B3
        }
        value ^= 0xFF  // separator, so "ab"+"c" and "a"+"bc" differ
        value = value &* 0x0000_0100_0000_01B3
        var mixed = value
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        value = mixed ^ (mixed >> 31)
    }
}
