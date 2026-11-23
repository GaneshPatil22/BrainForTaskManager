import BrainCore
import BrainHarness
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Calls the Gemini **Decisions API** — a closed-set classifier, not a text
/// generator.
///
/// The request shape below was derived by probing the live endpoint on
/// 2026-11-23; the documentation URL 404s and the model's
/// `supportedGenerationMethods` only says `createDecision`. Recorded here
/// because it is not findable anywhere else:
///
/// ```
/// POST https://generativelanguage.googleapis.com/v1beta/decisions
/// {
///   "model": "models/gemini-decision-1",
///   "input": [{"type": "text", "text": "<the capture>"}],
///   "questions": {
///     "<key>": {
///       "type": "choice",                       // or "score", "noul"
///       "instructions": "...",
///       "criteria": {"task": "something to do", ...}   // a MAP, 2-255 entries
///     }
///   }
/// }
/// ```
///
/// Why this matters more than a cheaper token price
/// ------------------------------------------------
/// Three of the guards in `docs/07-harness-spec.md` stop being defensive and
/// become structural:
///
/// - **Guard 1 (ID whitelist):** the answer is a key from `criteria`. An id
///   outside the candidate set is not rejected after the fact — it cannot be
///   expressed.
/// - **Guard 3 (schema):** there is no free text to parse, so there is no
///   invalid-JSON recovery path to measure.
/// - **Guard 4 (abstention):** `confidence` and a full probability
///   distribution come back natively. With `generateContent` we had to invent
///   a confidence of 1.0, which made the abstention threshold meaningless.
///
/// Measured on the first call: 124 tokens against Gemma 4's 601, and **zero
/// output tokens** because there is no reasoning to emit.
public struct DecisionProvider: LLMProvider {
    public let id: ProviderID
    public let model: String
    private let apiKey: String
    private let session: URLSession
    private let timeout: TimeInterval
    /// One-line descriptions per allowed answer. The API wants a map, and the
    /// descriptions measurably help a short, ambiguous capture.
    private let criteria: [String: String]
    private let instructions: String

    public init(
        model: String = "gemini-decision-1", apiKey: String,
        instructions: String, criteria: [String: String],
        timeout: TimeInterval = 30, session: URLSession = .shared
    ) {
        self.id = ProviderID("google-decisions/\(model)")
        self.model = model
        self.apiKey = apiKey
        self.instructions = instructions
        self.criteria = criteria
        self.timeout = timeout
        self.session = session
    }

    /// No thinking allowance: output tokens are zero by construction, so the
    /// prompt is the whole cost.
    public func estimateTokens(_ request: ModelRequest) -> Int {
        estimateTokenCount(request.system + request.untrustedContent)
    }

    public func complete(_ request: ModelRequest) async throws -> ModelResponse {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/decisions")!
        var http = URLRequest(url: url, timeoutInterval: timeout)
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        // Only the permitted answers are offered, so the model cannot name
        // anything else. Any criteria key we do not allow is dropped rather
        // than silently widening the option set.
        let allowed = Set(request.allowedAnswers)
        var options = criteria.filter { allowed.contains($0.key) }
        for answer in request.allowedAnswers where options[answer] == nil {
            options[answer] = answer
        }

        let body: [String: Any] = [
            "model": "models/\(model)",
            // The capture travels as input, never inside the instructions
            // (guard 9). No tools exist on this API at all.
            "input": [["type": "text", "text": request.untrustedContent]],
            "questions": [
                "answer": [
                    "type": "choice",
                    "instructions": instructions,
                    "criteria": options,
                ]
            ],
        ]
        http.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: http)
        } catch {
            throw ProviderError.transport("\(error.localizedDescription)")
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw ProviderError.transport("no HTTP status")
        }
        if status == 429 { throw ProviderError.rateLimited(retryAfter: nil) }
        guard (200..<300).contains(status) else {
            throw ProviderError.transport(
                "HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        return try Self.parse(data, questionKey: "answer")
    }

    /// Extracted so the parsing can be tested without a network call — the
    /// lesson from `GoogleProvider`, where both bugs were in this step.
    static func parse(_ data: Data, questionKey: String) throws -> ModelResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.malformedOutput("response is not JSON")
        }
        if let error = json["error"] as? [String: Any] {
            throw ProviderError.malformedOutput("\(error["message"] ?? "unknown")")
        }
        guard let answers = json["answers"] as? [String: Any],
            let answer = answers[questionKey] as? [String: Any]
        else {
            // No answer is an abstention, not a crash.
            return .abstained
        }

        let choice = answer["choice"] as? String
        // Natively calibrated, unlike a generated answer where any confidence
        // we attached would have been invented.
        let confidence = answer["confidence"] as? Double ?? 0
        let usage = json["usage"] as? [String: Any] ?? [:]

        let probabilities = answer["probabilities"] as? [String: Double] ?? [:]

        return ModelResponse(
            answer: choice,
            confidence: confidence,
            promptTokens: usage["total_input_tokens"] as? Int ?? 0,
            completionTokens: usage["total_output_tokens"] as? Int ?? 0,
            raw: choice ?? "",
            probabilities: probabilities)
    }
}

/// Free-tier limits for the Decisions API, from Ganesh's AI Studio account.
public enum DecisionLimits {
    public static let geminiDecision1 = ModelLimits(
        requestsPerMinute: 200, tokensPerMinute: 50_000, requestsPerDay: 10_000)
}
