import BrainCore
import BrainHarness
import Foundation
import Testing

@testable import BrainPipeline

/// Effort escalating to a model when the rules read no duration.
///
/// **Why this field earns a call.** `EffortBucket.unknown` is scored as
/// medium — 60 minutes, `docs/02-scoring-spec.md` — so a capture whose size
/// the rules cannot read does not score neutrally. It silently claims an hour
/// of the day, and it does so for most captures: measured on real ones, the
/// effort rules read **two of six**.
///
/// **Why `dueAt` is not here beside it.** Guard 5 of
/// `docs/07-harness-spec.md` is marked not-toggleable: "any model-supplied
/// date" is rejected, "T0 parse is the only source". That is a correctness
/// invariant, not a preference, and a day-count a model picks is still the
/// model deciding the deadline.
@Suite("Effort escalation")
struct EffortEscalationTests {
    static let zone = TimeZone(identifier: "Asia/Kolkata")!
    static let now = Date(timeIntervalSince1970: 1_795_404_600)

    func generator() -> ULIDGenerator {
        ULIDGenerator(seed: 5, clock: { UInt64(Self.now.timeIntervalSince1970 * 1000) })
    }

    func router(_ provider: FakeModel) -> ModelRouter {
        ModelRouter(
            ladders: [
                .estimateEffort: [
                    Rung(name: "t2", action: .provider(provider), model: "m", tier: .t2),
                    Rung(name: "degrade", action: .degrade, model: "-", tier: .t0),
                ]
            ],
            ledger: BudgetLedger(), mode: .live)
    }

    func enrich(_ text: String, router: ModelRouter?, _ gen: inout ULIDGenerator) async
        -> EnrichmentResult
    {
        let input = Capture(id: gen.next(), rawText: text, createdAt: Self.now)
        return await EnrichmentPipeline(timeZone: Self.zone, router: router).enrich(
            capture: input, graph: BrainGraph(), now: Self.now, idGenerator: &gen,
            requester: .local)
    }

    @Test("A capture with no stated duration is escalated")
    func escalatesOnAbstention() async {
        var gen = generator()
        let result = await enrich(
            "call the plumber", router: router(FakeModel.firstAllowed()), &gen)

        #expect(result.trace.routedCapabilities.contains(Capability.estimateEffort.rawValue))
        #expect(result.item.effort.value != nil)
        #expect(result.trace.tierByField["effort"] == .t2)
    }

    /// The Justification Test in reverse: a stated duration is not a model's
    /// job, and sending it anyway would spend quota to re-derive an answer
    /// the rules already hold.
    @Test("A stated duration is never sent to a model")
    func t0Wins() async {
        var gen = generator()
        let result = await enrich(
            "call the plumber 20 minutes", router: router(FakeModel.misbehaves()), &gen)

        #expect(result.trace.tierByField["effort"] == .t0)
        #expect(!result.trace.routedCapabilities.contains(Capability.estimateEffort.rawValue))
        #expect(result.item.effort.value == .small, "the rules read it, not the model")
    }

    /// Abstention is a legal answer at every rung (guard 4), and so is the
    /// model explicitly saying "unknown" — both leave the field unresolved
    /// rather than inventing a bucket.
    @Test("A model that abstains leaves effort unresolved")
    func abstentionIsLegal() async {
        var gen = generator()
        let result = await enrich(
            "call the plumber", router: router(FakeModel.alwaysAbstains()), &gen)

        #expect(result.trace.unresolved.contains("effort"))
        #expect(result.item.effort.value == nil)
        #expect(result.trace.tierByField["effort"] == nil, "no tier settled it")
    }

    /// With no router at all — the CLI, the evals — behaviour is exactly what
    /// it was before this change.
    @Test("No router means no escalation and no crash")
    func noRouter() async {
        var gen = generator()
        let result = await enrich("call the plumber", router: nil, &gen)
        #expect(result.trace.unresolved.contains("effort"))
        #expect(result.trace.routedCapabilities.isEmpty)
    }

    /// Guard 5, asserted where someone would try to add it.
    @Test("Due dates are never escalated, whatever the router offers")
    func datesAreNeverRouted() async {
        var gen = generator()
        let everything = ModelRouter(
            ladders: [
                .classifyType: [
                    Rung(
                        name: "t2", action: .provider(FakeModel.firstAllowed()), model: "m",
                        tier: .t2)
                ],
                .estimateEffort: [
                    Rung(
                        name: "t2", action: .provider(FakeModel.firstAllowed()), model: "m",
                        tier: .t2)
                ],
            ],
            ledger: BudgetLedger(), mode: .live)

        // No date-shaped text at all, so T0 certainly abstains.
        let result = await enrich("call the plumber", router: everything, &gen)
        #expect(result.item.dueAt.value == nil, "guard 5: T0 parse is the only source")
        #expect(result.trace.unresolved.contains("dueAt"))
    }
}
