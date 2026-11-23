import BrainCore
import Foundation

/// One rung of the escalation ladder.
///
/// Order is escalation order. The last rung must always be `.degrade`, because
/// a capture is never lost: if every provider is exhausted or broken, the
/// pipeline leaves the field unknown and moves on (`docs/07-harness-spec.md`).
public struct Rung: Sendable {
    public enum Action: Sendable {
        case provider(any LLMProvider)
        /// Hand the question to the user instead of a model. Placed **before**
        /// the paid rungs for low-stakes, reversible decisions: asking costs
        /// nothing, buys a training label, and is more honest than a guess
        /// (`docs/09-tiering.md`, T3).
        case askUser
        /// Give up on this field, keep the capture. Always last.
        case degrade
    }

    public let name: String
    public let action: Action
    public let model: String
    public let tier: Tier
    /// Accept this rung's answer only at or above this confidence. Chosen from
    /// the measured cost/accuracy curve in B5, not by feel.
    public let acceptAbove: Double

    public init(
        name: String, action: Action, model: String, tier: Tier, acceptAbove: Double = 0
    ) {
        self.name = name
        self.action = action
        self.model = model
        self.tier = tier
        self.acceptAbove = acceptAbove
    }
}

/// What happened on one routed call, for the trace.
public struct RouteTrace: Sendable {
    public var capability: Capability
    public var chosen: String?
    public var tier: Tier?
    /// Rungs skipped, and why — budget, breaker, confidence, cassette miss.
    public var skipped: [(rung: String, reason: String)] = []
    public var guardsFired: [GuardName] = []
    public var estimatedTokens = 0
    public var cassetteHit = false
    public var degraded = false
}

public struct RoutedAnswer: Sendable {
    public let value: String?
    public let confidence: Double
    public let tier: Tier?
    public let trace: RouteTrace
}

/// Walks the ladder: first rung with budget, a closed breaker and sufficient
/// confidence wins.
///
/// The pipeline asks for a `Capability` and never learns which rung answered,
/// so replacing Google with Groq is a config edit and one adapter file
/// (`docs/06-model-router.md`).
public actor ModelRouter {
    private let ladders: [Capability: [Rung]]
    private let ledger: BudgetLedger
    private let cassettes: CassetteStore?
    private let mode: CassetteMode
    private let guards: GuardConfig
    private var breakers: [String: CircuitBreaker] = [:]

    public init(
        ladders: [Capability: [Rung]], ledger: BudgetLedger,
        cassettes: CassetteStore? = nil, mode: CassetteMode = .replay,
        guards: GuardConfig = .all
    ) {
        self.ladders = ladders
        self.ledger = ledger
        self.cassettes = cassettes
        self.mode = mode
        self.guards = guards
    }

    private func breaker(for name: String) -> CircuitBreaker {
        if let existing = breakers[name] { return existing }
        let created = CircuitBreaker()
        breakers[name] = created
        return created
    }

    public func route(
        _ request: ModelRequest, user: String? = nil, userLimit: Int? = nil
    ) async -> RoutedAnswer {
        var trace = RouteTrace(capability: request.capability)
        let ladder = ladders[request.capability] ?? []

        for rung in ladder {
            switch rung.action {
            case .degrade:
                trace.degraded = true
                return RoutedAnswer(value: nil, confidence: 0, tier: nil, trace: trace)

            case .askUser:
                // The caller decides whether asking is appropriate here; the
                // router only records that this is where it would happen.
                trace.chosen = rung.name
                trace.tier = .t3
                return RoutedAnswer(value: nil, confidence: 0, tier: .t3, trace: trace)

            case .provider(let provider):
                let breaker = breaker(for: rung.name)
                guard await breaker.allows() else {
                    trace.skipped.append((rung.name, "circuit open"))
                    continue
                }

                let tokens = provider.estimateTokens(request)
                do {
                    try await ledger.consume(
                        model: rung.model, estimatedTokens: tokens,
                        user: user, userLimit: userLimit)
                } catch {
                    trace.skipped.append((rung.name, "\(error)"))
                    continue
                }
                trace.estimatedTokens += tokens

                let response: ModelResponse
                do {
                    if mode == .replay, let cassettes {
                        response = try await cassettes.replay(request)
                        trace.cassetteHit = true
                    } else {
                        if let cassettes, let cached = await cassettes.lookup(request) {
                            response = cached
                            trace.cassetteHit = true
                        } else {
                            response = try await provider.complete(request)
                            try? await cassettes?.write(
                                request, response: response, model: rung.model)
                        }
                    }
                    await breaker.recordSuccess()
                } catch {
                    await breaker.recordFailure()
                    trace.skipped.append((rung.name, "\(error)"))
                    continue
                }

                // Guards, in the order a wrong answer would do damage.
                var value = response.answer
                var outcome = Guards.schema(
                    raw: response.raw, allowed: request.allowedAnswers, enabled: guards.schema)
                trace.guardsFired += outcome.fired
                value = outcome.accepted

                outcome = Guards.idWhitelist(
                    answer: value, allowed: request.allowedAnswers, enabled: guards.idWhitelist)
                trace.guardsFired += outcome.fired
                value = outcome.accepted

                outcome = Guards.abstention(
                    answer: value, confidence: response.confidence,
                    threshold: rung.acceptAbove, enabled: guards.abstention)
                trace.guardsFired += outcome.fired
                value = outcome.accepted

                // A rung that produced nothing is not an answer. Fall through
                // and let a later rung try, rather than reporting an
                // abstention the ladder had not finished considering.
                guard let value else {
                    trace.skipped.append((rung.name, "guards rejected the answer"))
                    continue
                }
                trace.chosen = rung.name
                trace.tier = rung.tier
                return RoutedAnswer(
                    value: value, confidence: response.confidence,
                    tier: rung.tier, trace: trace)
            }
        }

        // Ladder exhausted with no `degrade` rung: still never an error.
        trace.degraded = true
        return RoutedAnswer(value: nil, confidence: 0, tier: nil, trace: trace)
    }
}
