import BrainCore
import BrainHarness
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Calls Google's `generateContent` endpoint.
///
/// Model ids verified against the live `models` listing for this account on
/// 2026-11-23 — not guessed, and not copied from documentation that has moved
/// twice this year:
///
/// | id | free RPM / TPM / RPD |
/// |---|---|
/// | `gemma-4-26b-a4b-it` | 30 / 16,000 / **14,400** |
/// | `gemma-4-31b-it` | 30 / 16,000 / 14,400 |
/// | `gemini-3.1-flash-lite` | 15 / 250,000 / 500 |
/// | `gemini-3.5-flash-lite` | 15 / 250,000 / 500 |
///
/// `gemini-decision-1` is deliberately absent: it is a separate Decisions API,
/// not a `generateContent` model, and needs its own adapter.
public struct GoogleProvider: LLMProvider {
    public let id: ProviderID
    public let model: String
    private let apiKey: String
    private let session: URLSession
    private let timeout: TimeInterval

    public init(
        model: String, apiKey: String, timeout: TimeInterval = 20,
        session: URLSession = .shared
    ) {
        self.id = ProviderID("google/\(model)")
        self.model = model
        self.apiKey = apiKey
        self.timeout = timeout
        self.session = session
    }

    /// Prompt tokens **plus a thinking allowance**.
    ///
    /// Measured on this account: a 27-token prompt to `gemma-4-26b-a4b-it`
    /// produced 223 thinking tokens and a 1-token answer — 251 total, nine
    /// times the prompt. Estimating the prompt alone under-counted TPM by that
    /// factor and would have walked straight into 429s partway through a
    /// record run. Thinking cannot be disabled on this model; the budget has
    /// to absorb it.
    public func estimateTokens(_ request: ModelRequest) -> Int {
        let prompt = estimateTokenCount(request.system + request.untrustedContent)
        return prompt + Self.thinkingAllowance(for: model)
    }

    /// Conservative: being refused costs more than reserving a few tokens too
    /// many, and an under-estimate is what produces a 429 mid-run.
    static func thinkingAllowance(for model: String) -> Int {
        model.hasPrefix("gemma-4") ? 350 : 0
    }

    public func complete(_ request: ModelRequest) async throws -> ModelResponse {
        let url = URL(
            string:
                "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        )!
        var http = URLRequest(url: url, timeoutInterval: timeout)
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        // The capture is passed as its own delimited turn and never
        // interpolated into the instructions (guard 9). No tools are declared,
        // so there is nothing for an injection to reach.
        let prompt = """
            \(request.system)

            Answer with exactly one of: \(request.allowedAnswers.joined(separator: ", ")), or unknown.

            <capture>
            \(request.untrustedContent)
            </capture>
            """

        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": [
                // Temperature 0 so a recorded cassette is reproducible. A
                // sampled answer would make replay a lie.
                "temperature": 0,
                "maxOutputTokens": 2048,
                "candidateCount": 1,
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
        if status == 429 {
            throw ProviderError.rateLimited(retryAfter: Self.retryAfter(response))
        }
        guard (200..<300).contains(status) else {
            let detail = String(decoding: data.prefix(300), as: UTF8.self)
            throw ProviderError.transport("HTTP \(status): \(detail)")
        }

        return try Self.parse(data)
    }

    /// Turns a `generateContent` response body into a `ModelResponse`.
    ///
    /// Extracted from `complete` because this is where both live-call bugs
    /// were: thought parts being concatenated into the answer, and thinking
    /// tokens going uncounted. Network code cannot be unit tested; this can.
    static func parse(_ data: Data) throws -> ModelResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.malformedOutput("response is not JSON")
        }
        // A blocked or empty candidate is an abstention, not a crash: the
        // pipeline must degrade, never throw (`docs/07-harness-spec.md`).
        let candidates = json["candidates"] as? [[String: Any]] ?? []
        let parts =
            candidates.first
            .flatMap { $0["content"] as? [String: Any] }
            .flatMap { $0["parts"] as? [[String: Any]] } ?? []

        // Gemma 4 is a thinking model: the reasoning arrives as a part marked
        // `"thought": true`, and the answer follows in a separate part.
        // Joining them all produced a cassette containing the model's working
        // instead of its answer — caught on the first real call.
        let text =
            parts
            .filter { ($0["thought"] as? Bool) != true }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let usage = json["usageMetadata"] as? [String: Any] ?? [:]
        return ModelResponse(
            answer: text.isEmpty ? nil : text,
            // These models do not report a calibrated confidence. Claiming one
            // would be inventing a number, so the router's threshold is the
            // only confidence gate until a model that does report one is used.
            confidence: text.isEmpty ? 0 : 1.0,
            promptTokens: usage["promptTokenCount"] as? Int ?? 0,
            // Thinking tokens count against TPM, so they belong in the
            // completion figure rather than being invisible.
            completionTokens: (usage["candidatesTokenCount"] as? Int ?? 0)
                + (usage["thoughtsTokenCount"] as? Int ?? 0),
            raw: text)
    }

    static func retryAfter(_ response: URLResponse) -> TimeInterval? {
        guard let http = response as? HTTPURLResponse,
            let value = http.value(forHTTPHeaderField: "Retry-After"),
            let seconds = TimeInterval(value)
        else { return nil }
        return seconds
    }
}

/// Free-tier limits, verified from Ganesh's AI Studio account on 2026-11-23.
///
/// **Configuration with a verification date, not constants.** Google changed
/// these unilaterally at least twice during 2026, so they live next to the
/// adapter and are re-checked at each phase gate.
public enum GoogleLimits {
    public static let table: [String: ModelLimits] = [
        "gemma-4-26b-a4b-it": ModelLimits(
            requestsPerMinute: 30, tokensPerMinute: 16_000, requestsPerDay: 14_400),
        "gemma-4-31b-it": ModelLimits(
            requestsPerMinute: 30, tokensPerMinute: 16_000, requestsPerDay: 14_400),
        "gemini-3.1-flash-lite": ModelLimits(
            requestsPerMinute: 15, tokensPerMinute: 250_000, requestsPerDay: 500),
        "gemini-3.5-flash-lite": ModelLimits(
            requestsPerMinute: 15, tokensPerMinute: 250_000, requestsPerDay: 500),
    ]

    public static func limits(for model: String) -> ModelLimits {
        table[model]
            ?? ModelLimits(
                requestsPerMinute: 5, tokensPerMinute: 16_000, requestsPerDay: 20)
    }
}
