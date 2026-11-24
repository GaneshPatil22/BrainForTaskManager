import BrainCore
import BrainHarness
import Foundation
import Testing

@testable import BrainPipeline

/// T3: asking beats guessing, and beats leaving a field blank forever
/// (`docs/09-tiering.md`).
///
/// Until now nothing in the system produced a question. `/v1/questions`
/// returned `[]` unconditionally, the web app's "Brain has a question" card
/// could never appear in production, and a capture every tier abstained on
/// simply kept an unknown type for good.
@Suite("T3 questions")
struct QuestionTests {
    static let zone = TimeZone(identifier: "Asia/Kolkata")!
    /// Monday 23 Nov 2026, 09:00 IST.
    static let now = Date(timeIntervalSince1970: 1_795_404_600)

    /// Measured, not assumed: the rules abstain on this one. A short verbless
    /// capture like "that pricing thing" is filed as a `note`, so it would
    /// never reach T3.
    static let abstains = "the whole situation with the vendor and the pricing and everything else"

    func pipeline(router: ModelRouter? = nil) -> EnrichmentPipeline {
        EnrichmentPipeline(timeZone: Self.zone, router: router)
    }

    func generator() -> ULIDGenerator {
        ULIDGenerator(seed: 1, clock: { UInt64(Self.now.timeIntervalSince1970 * 1000) })
    }

    func enrich(_ text: String, router: ModelRouter? = nil) async -> EnrichmentResult {
        var gen = generator()
        let input = Capture(id: gen.next(), rawText: text, createdAt: Self.now)
        return await pipeline(router: router).enrich(
            capture: input, graph: BrainGraph(), now: Self.now,
            idGenerator: &gen, requester: .local)
    }

    @Test("A capture no tier can type produces a question")
    func abstentionAsks() async {
        let result = await enrich(Self.abstains)
        #expect(result.item.type.value == nil, "the premise: the rules abstain")
        #expect(result.questions.count == 1)
        #expect(result.questions.first?.field == "type")
        #expect(result.trace.askUser == ["type"])
        #expect(result.trace.unresolved.contains("type"))
    }

    /// The answer has to be checkable against a closed set — that is the whole
    /// hallucination-prevention strategy, and it applies to a human's answer
    /// arriving back over HTTP too.
    @Test("The options are exactly the type vocabulary")
    func optionsAreClosed() async {
        let result = await enrich(Self.abstains)
        #expect(result.questions.first?.options == ItemType.allCases.map(\.rawValue))
        #expect(result.questions.first?.options.count == 5)
    }

    @Test("The question quotes the user's own words")
    func quotesTheCapture() async {
        let result = await enrich(Self.abstains)
        let prompt = result.questions.first?.prompt ?? ""
        #expect(prompt.contains("vendor"), "the person should recognise what is being asked about")
    }

    @Test("A long capture is truncated in the prompt, not dumped whole")
    func truncatesLongTitles() async {
        let long = String(repeating: "something about the vendor situation ", count: 10)
        let result = await enrich(long)
        let prompt = result.questions.first?.prompt ?? ""
        #expect(prompt.count < 120, "got \(prompt.count) characters")
        #expect(prompt.hasSuffix("…”?"))
    }

    @Test("A capture the rules can type is never asked about")
    func t0ResolvedAsksNothing() async {
        let result = await enrich("Kal plumber ko call krna h, 20 min ka kaam")
        #expect(result.item.type.value == .task)
        #expect(result.trace.tierByField["type"] == .t0)
        #expect(result.questions.isEmpty, "asking about something already settled is noise")
    }

    @Test("A question never costs the capture")
    func captureSurvives() async {
        let result = await enrich(Self.abstains)
        #expect(result.capture.status == .enriched)
        #expect(result.capture.rawText == Self.abstains)
        #expect(!result.item.title.isEmpty)
    }

    // MARK: - With a router

    /// A router that answers settles the field, and nothing is asked. This is
    /// the case that justifies asking *after* the ladder rather than before
    /// it: in the production trial six of seven captures settled at T0 and the
    /// seventh at T2, so asking ahead of T2 would have produced a question the
    /// model answered correctly for nothing.
    @Test("A router that answers prevents the question")
    func routerAnswerPreventsQuestion() async {
        let router = ModelRouter(
            ladders: [
                .classifyType: [
                    Rung(
                        name: "answers", action: .provider(FakeModel.firstAllowed()),
                        model: "m", tier: .t2)
                ]
            ],
            ledger: BudgetLedger(), mode: .live)
        let result = await enrich(Self.abstains, router: router)
        #expect(result.item.type.value == ItemType.allCases.first)
        #expect(result.trace.tierByField["type"] == .t2)
        #expect(result.questions.isEmpty)
        #expect(result.trace.askUser.isEmpty)
    }

    /// A ladder that degrades asks, rather than leaving the field blank.
    @Test("A router that abstains still produces the question")
    func routerAbstentionAsks() async {
        let router = ModelRouter(
            ladders: [
                .classifyType: [
                    Rung(
                        name: "abstains", action: .provider(FakeModel.alwaysAbstains()),
                        model: "m", tier: .t2),
                    Rung(name: "give-up", action: .degrade, model: "-", tier: .t0),
                ]
            ],
            ledger: BudgetLedger(), mode: .live)
        let result = await enrich(Self.abstains, router: router)
        #expect(result.item.type.value == nil)
        #expect(result.questions.count == 1)
        #expect(result.trace.askUser == ["type"])
    }

    /// An explicit `askUser` rung returns no value by design, so it must reach
    /// the same question rather than falling through to nothing.
    @Test("An askUser rung reaches the question")
    func askUserRungAsks() async {
        let router = ModelRouter(
            ladders: [.classifyType: [Rung(name: "ask", action: .askUser, model: "-", tier: .t3)]],
            ledger: BudgetLedger(), mode: .live)
        let result = await enrich(Self.abstains, router: router)
        #expect(result.questions.count == 1)
        #expect(result.questions.first?.field == "type")
        #expect(result.trace.askUser == ["type"])
    }
}
