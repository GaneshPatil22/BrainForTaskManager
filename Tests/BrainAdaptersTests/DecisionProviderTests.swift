import BrainCore
import BrainHarness
import Foundation
import Testing

@testable import BrainAdapters

/// The Decisions API returns a choice from a closed set plus a calibrated
/// distribution. Payloads below are verbatim from the live endpoint.
@Suite("DecisionProvider — closed-set answers")
struct DecisionProviderTests {

    /// Exactly what the live API returned for
    /// "kal subah plumber ko call krna h".
    static let realResponse = """
        {"answers":{"answer":{"confidence":0.5770874629802988,"choice":"task",
         "probabilities":{"note":0.0287978787,"task":0.5770874629,"reminder":0.3863040456,
                          "link":0.0030571734,"idea":0.0047534392},"type":"choice"}},
         "usage":{"total_tokens":124,"total_input_tokens":124,"total_output_tokens":0}}
        """

    @Test("The choice and its calibrated confidence are read")
    func readsChoice() throws {
        let response = try DecisionProvider.parse(
            Data(Self.realResponse.utf8), questionKey: "answer")
        #expect(response.answer == "task")
        #expect(abs(response.confidence - 0.577) < 0.001)
    }

    /// ECE is a scorecard metric and cannot be recomputed from a single
    /// confidence number, so the full distribution has to survive into the
    /// cassette.
    @Test("The full probability distribution is kept")
    func keepsDistribution() throws {
        let response = try DecisionProvider.parse(
            Data(Self.realResponse.utf8), questionKey: "answer")
        #expect(response.probabilities.count == 5)
        #expect(abs((response.probabilities["reminder"] ?? 0) - 0.386) < 0.001)
        // Probabilities should be a distribution, not arbitrary scores.
        let total = response.probabilities.values.reduce(0, +)
        #expect(abs(total - 1.0) < 0.01)
    }

    /// Zero output tokens is the structural advantage: there is no generated
    /// text, so nothing to parse and nothing to pay for.
    @Test("Output tokens are zero, input is counted")
    func tokens() throws {
        let response = try DecisionProvider.parse(
            Data(Self.realResponse.utf8), questionKey: "answer")
        #expect(response.promptTokens == 124)
        #expect(response.completionTokens == 0)
    }

    /// A low-confidence answer is exactly the case guard 4 exists for. On this
    /// real payload the model chose `task` at 0.58 while the true label is
    /// `reminder` at 0.39 — wrong, but honestly unsure, so a threshold catches
    /// it. With a generating model we invented a confidence of 1.0 and had
    /// nothing to threshold on.
    @Test("A genuinely unsure answer is below a sensible threshold")
    func lowConfidenceIsCatchable() throws {
        let response = try DecisionProvider.parse(
            Data(Self.realResponse.utf8), questionKey: "answer")
        let outcome = Guards.abstention(
            answer: response.answer, confidence: response.confidence, threshold: 0.7)
        #expect(outcome.accepted == nil)
        #expect(outcome.fired == [.abstention])
    }

    @Test("A missing answer abstains rather than throwing")
    func abstains() throws {
        for body in [#"{"answers":{}}"#, #"{"usage":{}}"#] {
            let response = try DecisionProvider.parse(Data(body.utf8), questionKey: "answer")
            #expect(response.answer == nil, "\(body)")
        }
    }

    @Test("An API error surfaces as malformed output")
    func apiError() {
        let body = #"{"error":{"message":"Model name cannot be empty.","code":"invalid_request"}}"#
        #expect(throws: ProviderError.self) {
            try DecisionProvider.parse(Data(body.utf8), questionKey: "answer")
        }
    }

    /// No thinking tokens to allow for, unlike Gemma.
    @Test("The estimate carries no thinking allowance")
    func estimate() {
        let request = ModelRequest(
            capability: .classifyType, system: "sys", untrustedContent: "buy milk",
            allowedAnswers: ["task"], promptVersion: "v1")
        let decisions = DecisionProvider(
            apiKey: "x", instructions: "i", criteria: ["task": "a task"])
        let gemma = GoogleProvider(model: "gemma-4-26b-a4b-it", apiKey: "x")
        #expect(decisions.estimateTokens(request) < gemma.estimateTokens(request))
    }
}
