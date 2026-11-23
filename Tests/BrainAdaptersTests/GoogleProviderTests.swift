import BrainCore
import BrainHarness
import Foundation
import Testing

@testable import BrainAdapters

/// Response parsing, tested against real captured payloads. Both bugs this
/// pins were found by the first live calls, not by review.
@Suite("GoogleProvider — response parsing")
struct GoogleProviderTests {

    /// Verbatim shape of a real `gemma-4-26b-a4b-it` reply: the reasoning
    /// arrives as a part flagged `thought`, the answer as a separate part.
    /// Joining them recorded the model's working instead of its answer.
    @Test("Thought parts are excluded from the answer")
    func thoughtPartsExcluded() throws {
        let body = """
            {"candidates":[{"content":{"parts":[
              {"text":"*   Input: `buy milk`\\n    *   Reasoning: this is an action","thought":true},
              {"text":"task"}
            ]},"finishReason":"STOP"}],
            "usageMetadata":{"promptTokenCount":27,"candidatesTokenCount":1,
                             "thoughtsTokenCount":223,"totalTokenCount":251}}
            """
        let response = try GoogleProvider.parse(Data(body.utf8))
        #expect(response.answer == "task")
        #expect(!response.raw.contains("Reasoning"))
    }

    /// Thinking tokens are billed against TPM. Counting only the answer
    /// under-reported a 251-token call as 1 token.
    @Test("Thinking tokens are counted, not ignored")
    func thinkingTokensCounted() throws {
        let body = """
            {"candidates":[{"content":{"parts":[{"text":"task"}]}}],
            "usageMetadata":{"promptTokenCount":27,"candidatesTokenCount":1,
                             "thoughtsTokenCount":223}}
            """
        let response = try GoogleProvider.parse(Data(body.utf8))
        #expect(response.promptTokens == 27)
        #expect(response.completionTokens == 224, "1 answer + 223 thinking")
    }

    /// Guard 5's cousin: the estimate feeds the TPM budget, and an estimate
    /// nine times under walks into 429s partway through a run.
    @Test("The estimate includes a thinking allowance for thinking models")
    func estimateIncludesThinking() {
        let request = ModelRequest(
            capability: .classifyType, system: "sys", untrustedContent: "buy milk",
            allowedAnswers: ["task"], promptVersion: "v1")
        let thinking = GoogleProvider(model: "gemma-4-26b-a4b-it", apiKey: "x")
        let plain = GoogleProvider(model: "gemini-3.1-flash-lite", apiKey: "x")
        #expect(thinking.estimateTokens(request) > plain.estimateTokens(request) + 300)
    }

    /// A blocked or empty candidate must read as an abstention. Throwing here
    /// would lose the capture.
    @Test("An empty or blocked response abstains rather than throwing")
    func emptyAbstains() throws {
        for body in [
            #"{"candidates":[]}"#,
            #"{"candidates":[{"content":{"parts":[]}}]}"#,
            #"{"candidates":[{"finishReason":"SAFETY"}]}"#,
        ] {
            let response = try GoogleProvider.parse(Data(body.utf8))
            #expect(response.answer == nil, "\(body)")
            #expect(response.confidence == 0, "\(body)")
        }
    }

    @Test("Non-JSON is a malformed-output error, not a crash")
    func malformed() {
        #expect(throws: ProviderError.self) {
            try GoogleProvider.parse(Data("not json at all".utf8))
        }
    }

    /// Verified against the live models listing on 2026-11-23, not guessed.
    @Test("Known models carry their published free-tier limits")
    func limits() {
        let gemma = GoogleLimits.limits(for: "gemma-4-26b-a4b-it")
        #expect(gemma.requestsPerDay == 14_400)
        #expect(gemma.tokensPerMinute == 16_000)
        // An unknown model gets the most pessimistic defaults, so a typo in a
        // config cannot silently assume a generous quota.
        let unknown = GoogleLimits.limits(for: "gemini-made-up")
        #expect(unknown.requestsPerDay == 20)
    }
}
