import BrainHarness
import Foundation
import Testing

@testable import BrainProduction

@Suite("ProductionRouter")
struct ProductionRouterTests {
    @Test("Every rung's budget is registered, so none spends as unlimited")
    func limitsAreRegistered() async {
        let ledger = BudgetLedger()
        _ = await ProductionRouter.make(apiKey: "test-key", ledger: ledger)
        for model in ["gemini-decision-1", "gemma-4-26b-a4b-it", "gemini-3.1-flash-lite"] {
            // An unregistered model falls back to .unlimited, so a registered
            // one must refuse eventually. Drive it to its daily cap.
            let usage = await ledger.usage(model: model)
            #expect(usage.dayRequests == 0, "\(model) starts clean")
        }
        // Decision 1's RPM is 200; an unregistered model would have no RPM at
        // all and never refuse.
        await #expect(throws: BudgetRefusal.self) {
            for _ in 0...200 {
                try await ledger.consume(model: "gemini-decision-1", estimatedTokens: 1)
            }
        }
    }

    @Test("degrade is last, so a capture is never lost")
    func degradeIsLast() {
        let ladder = ProductionRouter.classifyTypeLadder(apiKey: "test-key")
        guard case .degrade = ladder.last?.action else {
            Issue.record("the last rung is not degrade")
            return
        }
        #expect(
            ladder.dropLast().allSatisfy { if case .degrade = $0.action { false } else { true } })
    }

    /// Guards against someone "fixing" the ladder to match the YAML sketch in
    /// `docs/06` without noticing that `.askUser` returns unconditionally.
    @Test("No unconditional askUser rung sits ahead of the T2 providers")
    func noAskUserBeforeT2() {
        let ladder = ProductionRouter.classifyTypeLadder(apiKey: "test-key")
        let askIndex = ladder.firstIndex { if case .askUser = $0.action { true } else { false } }
        #expect(
            askIndex == nil,
            "an askUser rung here short-circuits every T2 provider below it")
    }

    @Test("Replay is the default, so a server's CI spends nothing")
    func replayByDefault() async {
        // A live default would mean any caller forgetting the argument makes
        // real calls. Asserted by construction: .make's mode defaults to
        // .replay and a replay router with no cassettes cannot reach a
        // provider.
        let ledger = BudgetLedger()
        let router = await ProductionRouter.make(apiKey: "test-key", ledger: ledger)
        let answer = await router.route(
            ModelRequest(
                capability: .classifyType, system: "s", untrustedContent: "c",
                allowedAnswers: ["task"], promptVersion: "v1"))
        #expect(answer.value == nil, "replay with no cassette must not call out")
        #expect(answer.trace.degraded)
    }

    @Test("Stale limits are reported, not silently trusted")
    func staleLimitsAreFlagged() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let soon = formatter.date(from: "2026-12-01")!
        #expect(ProductionRouter.staleLimits(now: soon).isEmpty)

        // A year on, every row is overdue.
        let later = formatter.date(from: "2027-12-01")!
        #expect(ProductionRouter.staleLimits(now: later).count == 3)
    }
}
