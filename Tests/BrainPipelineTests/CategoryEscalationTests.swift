import BrainCore
import BrainHarness
import Foundation
import Testing

@testable import BrainPipeline

/// Category escalating to a model when the lexicon abstains.
///
/// **Why category and not dates.** `brain compare` on the dev split puts
/// category at **67.0% end-to-end**, answering only 258 of 339, while dates
/// read 97.9%. Category is both the weakest field and the only one with no
/// escalation path, so it goes first — the dates this argument started over
/// are the ones the rules handle best.
///
/// **Graduated from a flag.** This shipped behind `EnrichmentFeatures
/// .categoryEscalation` precisely because the synthetic labels could not prove
/// it: the generator wrote both the captures and the labels, so the rules are
/// scored on the distribution they were authored against. 129 recorded answers
/// settled it — **67.0% → 87.3%, +20.4pp**, with the model right on 69 of the
/// 76 escalations that could be scored (90.8%, against the lexicon's 88.0%).
/// The flag is gone; escalation now happens whenever a router is attached.
@Suite("Category escalation")
struct CategoryEscalationTests {
    static let zone = TimeZone(identifier: "Asia/Kolkata")!
    static let now = Date(timeIntervalSince1970: 1_795_404_600)

    /// A capture the lexicon has no term for, so T0 certainly abstains.
    ///
    /// Measured, not assumed: my first guess here — "sort out the thing with
    /// the landlord's cousin" — is classified `chores` by the lexicon, and
    /// "follow up on that" is `communication`. The lexicon reaches further
    /// than it looks, which is exactly why a fixture for it has to be checked
    /// rather than invented.
    static let unknownToLexicon = "that matter we discussed"

    func generator() -> ULIDGenerator {
        ULIDGenerator(seed: 9, clock: { UInt64(Self.now.timeIntervalSince1970 * 1000) })
    }

    func router(_ provider: FakeModel) -> ModelRouter {
        ModelRouter(
            ladders: [
                .classifyCategory: [
                    Rung(name: "t2", action: .provider(provider), model: "m", tier: .t2),
                    Rung(name: "degrade", action: .degrade, model: "-", tier: .t0),
                ]
            ],
            ledger: BudgetLedger(), mode: .live)
    }

    func enrich(
        _ text: String, router: ModelRouter?, _ gen: inout ULIDGenerator
    ) async -> EnrichmentResult {
        let input = Capture(id: gen.next(), rawText: text, createdAt: Self.now)
        return await EnrichmentPipeline(timeZone: Self.zone, router: router).enrich(
            capture: input, graph: BrainGraph(), now: Self.now, idGenerator: &gen,
            requester: .local)
    }

    /// The router is the only switch there is now that the flag has gone. A
    /// pipeline built without one must still produce an item, with the
    /// lexicon's abstention left standing rather than filled in.
    @Test("With no router the lexicon's abstention stands")
    func noRouterEscalatesNothing() async {
        var gen = generator()
        let result = await enrich(Self.unknownToLexicon, router: nil, &gen)

        #expect(result.trace.routedCapabilities.isEmpty)
        #expect(result.item.category.value == nil)
        #expect(result.trace.unresolved.contains("category"))
    }

    @Test("An unknown category is escalated to the model")
    func escalates() async {
        var gen = generator()
        let result = await enrich(
            Self.unknownToLexicon, router: router(FakeModel.firstAllowed()), &gen)

        #expect(result.trace.routedCapabilities.contains(Capability.classifyCategory.rawValue))
        #expect(result.item.category.value != nil)
        #expect(result.trace.tierByField["category"] == .t2)
    }

    /// The Justification Test: a lexicon hit is not sent to a model. Spending
    /// a call to re-derive an answer we already hold is the waste the whole
    /// ladder exists to avoid.
    @Test("A category the lexicon knows is never sent to a model")
    func lexiconWins() async {
        var gen = generator()
        let result = await enrich(
            "pay the electricity bill", router: router(FakeModel.misbehaves()), &gen)

        #expect(result.trace.tierByField["category"] == .t0)
        #expect(!result.trace.routedCapabilities.contains(Capability.classifyCategory.rawValue))
        #expect(result.item.category.value == .money)
    }

    @Test("A model that abstains leaves the category unresolved")
    func abstentionIsLegal() async {
        var gen = generator()
        let result = await enrich(
            Self.unknownToLexicon, router: router(FakeModel.alwaysAbstains()), &gen)

        #expect(result.trace.unresolved.contains("category"))
        #expect(result.item.category.value == nil)
        #expect(result.trace.tierByField["category"] == nil, "no tier settled it")
    }

    /// `unknown` is offered to the model as a legal answer and is not a
    /// `TaskCategory`, so it has to come out as an abstention rather than as
    /// a failed parse that silently drops to the next rung.
    @Test("`unknown` from the model means abstained, not broken")
    func unknownIsAbstention() async {
        var gen = generator()
        let result = await enrich(
            Self.unknownToLexicon,  // `misbehaves` just returns a fixed answer; here that answer is legal.
            router: router(FakeModel.misbehaves(with: "unknown")), &gen)

        #expect(result.item.category.value == nil)
        #expect(result.trace.unresolved.contains("category"))
    }

    /// Every other field keeps the behaviour it had. This mattered while the
    /// flag existed, because it is what made the measured delta attributable
    /// to one field; it stays because the attribution is still the claim.
    @Test("Escalation touches category and nothing else")
    func scopedToCategory() async {
        var gen = generator()
        let result = await enrich(
            "pay the electricity bill kal 20 minutes",
            router: router(FakeModel.firstAllowed()), &gen)

        #expect(result.trace.tierByField["dueAt"] == .t0)
        #expect(result.trace.tierByField["effort"] == .t0)
        #expect(result.trace.tierByField["type"] == .t0)
    }
}
