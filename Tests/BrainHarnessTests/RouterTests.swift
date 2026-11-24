import BrainCore
import Foundation
import Testing

@testable import BrainHarness

/// The ladder is what turns "AI proposes" into something safe to run: budgets,
/// breakers and guards all have to fail *into* a working system, never out of
/// one. A capture is never lost (`docs/07-harness-spec.md`).
@Suite("ModelRouter — the escalation ladder")
struct RouterTests {
    func request(_ content: String = "call the plumber", allowed: [String] = ["task", "note"])
        -> ModelRequest
    {
        ModelRequest(
            capability: .classifyType, system: "sys", untrustedContent: content,
            allowedAnswers: allowed, promptVersion: "v1")
    }

    func router(_ rungs: [Rung], mode: CassetteMode = .live, guards: GuardConfig = .all)
        -> ModelRouter
    {
        ModelRouter(
            ladders: [.classifyType: rungs], ledger: BudgetLedger(),
            cassettes: nil, mode: mode, guards: guards)
    }

    @Test("The first healthy rung answers")
    func firstRungWins() async {
        let answer = await router([
            Rung(name: "a", action: .provider(FakeModel.firstAllowed()), model: "m1", tier: .t2),
            Rung(name: "b", action: .provider(FakeModel.misbehaves()), model: "m2", tier: .t2),
        ]).route(request())
        #expect(answer.value == "task")
        #expect(answer.trace.chosen == "a")
    }

    /// The core fallback promise: a dead provider costs latency, not a capture.
    @Test("A failing rung falls through to the next")
    func fallsThrough() async {
        let answer = await router([
            Rung(name: "dead", action: .provider(FakeModel.alwaysFails()), model: "m1", tier: .t2),
            Rung(
                name: "alive", action: .provider(FakeModel.firstAllowed()), model: "m2", tier: .t2),
        ]).route(request())
        #expect(answer.value == "task")
        #expect(answer.trace.chosen == "alive")
        #expect(answer.trace.skipped.first?.rung == "dead")
    }

    /// Guard 1 in the real path, not just in isolation.
    @Test("A fabricated id is rejected and the rung is skipped")
    func misbehavingRungRejected() async {
        let answer = await router([
            Rung(
                name: "liar", action: .provider(FakeModel.misbehaves(with: "item-99999")),
                model: "m1", tier: .t2),
            Rung(
                name: "honest", action: .provider(FakeModel.firstAllowed()),
                model: "m2", tier: .t2),
        ]).route(request())
        #expect(answer.value == "task")
        #expect(answer.trace.chosen == "honest")
    }

    @Test("Every rung exhausted degrades rather than throwing")
    func degradesGracefully() async {
        let answer = await router([
            Rung(name: "dead1", action: .provider(FakeModel.alwaysFails()), model: "m1", tier: .t2),
            Rung(name: "dead2", action: .provider(FakeModel.alwaysFails()), model: "m2", tier: .t2),
            Rung(name: "give-up", action: .degrade, model: "-", tier: .t0),
        ]).route(request())
        #expect(answer.value == nil)
        #expect(answer.trace.degraded)
    }

    /// T3 sits *before* the paid rungs: asking costs nothing and buys a label.
    @Test("askUser short-circuits before spending quota")
    func askUserComesFirst() async {
        let answer = await router([
            Rung(name: "ask", action: .askUser, model: "-", tier: .t3),
            Rung(name: "paid", action: .provider(FakeModel.firstAllowed()), model: "m", tier: .t2),
        ]).route(request())
        #expect(answer.tier == .t3)
        #expect(answer.value == nil)
        #expect(answer.trace.estimatedTokens == 0, "must not have charged a budget")
    }

    @Test("A low-confidence answer is rejected and the ladder continues")
    func confidenceThreshold() async {
        let answer = await router([
            Rung(
                name: "unsure", action: .provider(FakeModel.firstAllowed(confidence: 0.3)),
                model: "m1", tier: .t2, acceptAbove: 0.8),
            Rung(
                name: "sure", action: .provider(FakeModel.firstAllowed(confidence: 0.95)),
                model: "m2", tier: .t2, acceptAbove: 0.8),
        ]).route(request())
        #expect(answer.trace.chosen == "sure")
    }

    @Test("An abstaining provider does not block a later rung")
    func abstentionFallsThrough() async {
        let answer = await router([
            Rung(
                name: "quiet", action: .provider(FakeModel.alwaysAbstains()),
                model: "m1", tier: .t2),
            Rung(name: "loud", action: .provider(FakeModel.firstAllowed()), model: "m2", tier: .t2),
        ]).route(request())
        #expect(answer.value == "task")
    }
}

@Suite("BudgetLedger")
struct BudgetTests {
    @Test("RPD is enforced")
    func dailyLimit() async throws {
        let ledger = BudgetLedger()
        await ledger.setLimits(
            ModelLimits(requestsPerMinute: nil, tokensPerMinute: nil, requestsPerDay: 3),
            for: "m")
        for _ in 0..<3 { try await ledger.consume(model: "m", estimatedTokens: 1) }
        await #expect(throws: BudgetRefusal.requestsPerDay(limit: 3)) {
            try await ledger.consume(model: "m", estimatedTokens: 1)
        }
    }

    /// TPM is the binding free-tier constraint, and it is charged on the
    /// estimate before dispatch — you cannot stay under a budget you only
    /// measure after spending it.
    @Test("TPM is charged before the call, on the estimate")
    func tokensPerMinute() async throws {
        let ledger = BudgetLedger()
        await ledger.setLimits(
            ModelLimits(requestsPerMinute: nil, tokensPerMinute: 100, requestsPerDay: nil),
            for: "m")
        try await ledger.consume(model: "m", estimatedTokens: 60)
        await #expect(throws: BudgetRefusal.self) {
            try await ledger.consume(model: "m", estimatedTokens: 60)
        }
    }

    /// Without this one user's brain dump starves everyone until midnight.
    @Test("Per-user fair share is enforced separately from the pool")
    func fairShare() async throws {
        let ledger = BudgetLedger()
        await ledger.setLimits(
            ModelLimits(requestsPerMinute: nil, tokensPerMinute: nil, requestsPerDay: 1000),
            for: "m")
        for _ in 0..<2 {
            try await ledger.consume(model: "m", estimatedTokens: 1, user: "ganesh", userLimit: 2)
        }
        await #expect(throws: BudgetRefusal.self) {
            try await ledger.consume(model: "m", estimatedTokens: 1, user: "ganesh", userLimit: 2)
        }
        // A different user is unaffected — the pool still has room.
        try await ledger.consume(model: "m", estimatedTokens: 1, user: "other", userLimit: 2)
    }

    @Test("Fair share scales with the pool and the number of users")
    func fairShareFormula() {
        #expect(BudgetLedger.fairShare(dailyLimit: 14_400, activeUsers: 100) == 288)
        // Never so tight that one person feels throttled in normal use.
        #expect(BudgetLedger.fairShare(dailyLimit: 14_400, activeUsers: 100_000) == 50)
    }

    @Test("Unlimited models are never refused")
    func unlimited() async throws {
        let ledger = BudgetLedger()
        await ledger.setLimits(.unlimited, for: "local")
        for _ in 0..<500 { try await ledger.consume(model: "local", estimatedTokens: 10_000) }
    }
}

@Suite("CircuitBreaker")
struct BreakerTests {
    @Test("Opens after the threshold, and skips without calling")
    func opens() async {
        let breaker = CircuitBreaker(threshold: 3, cooldown: 60)
        for _ in 0..<3 { await breaker.recordFailure() }
        #expect(await breaker.state() == .open)
        #expect(await breaker.allows() == false)
    }

    /// A tiny mutable clock. A captured `var` cannot cross into a @Sendable
    /// closure, and a real sleep would make the test slow and flaky.
    final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ start: Date) { value = start }
        func read() -> Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) {
            lock.withLock { value = value.addingTimeInterval(seconds) }
        }
    }

    @Test("Half-opens after the cooldown and closes on success")
    func recovers() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        let breaker = CircuitBreaker(threshold: 2, cooldown: 30, now: { clock.read() })
        for _ in 0..<2 { await breaker.recordFailure() }
        #expect(await breaker.state() == .open)

        clock.advance(31)
        #expect(await breaker.state() == .halfOpen)
        #expect(await breaker.allows())

        await breaker.recordSuccess()
        #expect(await breaker.state() == .closed)
    }

    @Test("Success before the threshold resets the count")
    func resets() async {
        let breaker = CircuitBreaker(threshold: 3)
        await breaker.recordFailure()
        await breaker.recordFailure()
        await breaker.recordSuccess()
        await breaker.recordFailure()
        #expect(await breaker.state() == .closed)
    }
}

/// A cassette miss must not look like a provider outage.
///
/// **The bug this suite exists for.** The circuit breaker is keyed by rung
/// *name*, and every ladder in `ProductionRouter` uses the same names because
/// it uses the same models. A capability with no recordings therefore tripped
/// the breaker on its first capture, and every other capability behind the
/// same rung was skipped as "circuit open" — before it ever looked up its own
/// cassette.
///
/// Measured when it happened: 129 category cassettes on disk with real
/// answers, 425 calls attempted, **26 reaching the store**. The comparison
/// that produced read as "the model barely helps" — category +0.6pp. With a
/// miss no longer tripping the breaker: **+20.4pp**, and type went from
/// +0.2pp to +5.8pp, because type had been starved in every earlier run too.
@Suite("ModelRouter — a cassette miss is not an outage")
struct CassetteMissTests {
    /// A fresh directory, written through a `.record` store and read back
    /// through a `.replay` one — the same two-phase shape a real run has.
    func directory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("brain-cassette-miss-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func request(_ capability: Capability, _ content: String) -> ModelRequest {
        ModelRequest(
            capability: capability, system: "sys", untrustedContent: content,
            allowedAnswers: ["task", "note"], promptVersion: "v1")
    }

    /// Two capabilities, same rung name — the production shape exactly.
    @Test("A capability with no recordings does not starve the others")
    func missDoesNotOpenTheBreaker() async throws {
        let folder = try directory()
        let recorded = request(.classifyType, "recorded capture")
        let recorder = CassetteStore(directory: folder, mode: .record)
        try await recorder.write(
            recorded,
            response: ModelResponse(
                answer: "task", confidence: 0.9, promptTokens: 10, completionTokens: 0,
                raw: "task", probabilities: [:]),
            model: "m")

        let cassettes = CassetteStore(directory: folder, mode: .replay)
        let rung = Rung(
            name: "t2-decision", action: .provider(FakeModel.firstAllowed()), model: "m",
            tier: .t2)
        let router = ModelRouter(
            ladders: [.classifyType: [rung], .estimateEffort: [rung]],
            ledger: BudgetLedger(), cassettes: cassettes, mode: .replay)

        // Ten misses on one capability, the way a 415-capture run would.
        for index in 0..<10 {
            let answer = await router.route(request(.estimateEffort, "unrecorded \(index)"))
            #expect(answer.value == nil, "no recording, so no answer")
        }

        // The other capability's recording must still be reachable.
        let answer = await router.route(recorded)
        #expect(answer.value == "task", "a miss elsewhere must not close this rung")
        #expect(answer.trace.cassetteHit)
    }

    /// A real provider failure still opens the breaker — the fix must not
    /// disarm it, only stop it firing on the wrong signal.
    @Test("A genuine provider failure still opens the breaker")
    func realFailureStillTrips() async {
        let rung = Rung(
            name: "t2", action: .provider(FakeModel.alwaysFails()), model: "m", tier: .t2)
        let router = ModelRouter(
            ladders: [.classifyType: [rung]], ledger: BudgetLedger(), mode: .live)

        var sawOpenCircuit = false
        for index in 0..<10 {
            let answer = await router.route(request(.classifyType, "capture \(index)"))
            if answer.trace.skipped.contains(where: { $0.reason == "circuit open" }) {
                sawOpenCircuit = true
            }
        }
        #expect(sawOpenCircuit, "repeated real failures must still trip it")
    }
}
