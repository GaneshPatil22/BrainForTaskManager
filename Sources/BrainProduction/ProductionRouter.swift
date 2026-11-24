import BrainAdapters
import BrainCore
import BrainHarness
import BrainPipeline
import Foundation

/// The production model ladder, in one place.
///
/// `docs/06-model-router.md` described this as `config/router.prod.yaml`, and
/// that file never existed — only tests and CLI commands built rungs, each
/// slightly differently. The server must not re-invent Brain's ladder, so this
/// is the one supported way to build it.
///
/// ## Why code and not YAML
///
/// A YAML ladder needs a parser dependency Brain does not have, cannot be
/// type-checked, and drifts silently from the `Rung` API — which is exactly
/// what happened to the version in `docs/06`. The limits stay *data* with a
/// verification date, which is the part that actually changes.
public enum ProductionRouter {

    // MARK: - Free-tier limits

    /// When each row was last confirmed, and against what.
    ///
    /// Google changed these unilaterally at least twice in 2026, so a stale
    /// row is a real risk and the date is part of the data.
    public struct VerifiedLimits: Sendable {
        public let limits: ModelLimits
        public let verifiedOn: String
        public let source: String
    }

    /// Verified 2026-11-24 against Google's own documentation
    /// (`https://aistudio.google.com/docs/rate-limits`).
    public static let decision1 = VerifiedLimits(
        limits: DecisionLimits.geminiDecision1,
        verifiedOn: "2026-11-24",
        source: "aistudio.google.com/docs/rate-limits")

    /// **Not independently verifiable.** Google's public rate-limit page no
    /// longer publishes a per-model free-tier table — it says limits "can be
    /// viewed in Google AI Studio" and shows only Decision 1. These rows come
    /// from Ganesh's AI Studio dashboard on 2026-11-22 and cannot be checked
    /// without signing in to that account.
    ///
    /// Treated as expiring: `staleAfterDays` below drives a warning rather
    /// than letting an old number quietly govern spending.
    public static let gemma = VerifiedLimits(
        limits: GoogleLimits.limits(for: "gemma-4-26b-a4b-it"),
        verifiedOn: "2026-11-22",
        source: "Ganesh's AI Studio dashboard (login required)")

    public static let flashLite = VerifiedLimits(
        limits: GoogleLimits.limits(for: "gemini-3.1-flash-lite"),
        verifiedOn: "2026-11-22",
        source: "Ganesh's AI Studio dashboard (login required)")

    /// How long a limits row is trusted before the caller should re-check.
    public static let staleAfterDays = 90

    /// Rows whose verification is older than `staleAfterDays` at `now`.
    /// The server logs these at startup; they are not fatal.
    public static func staleLimits(now: Date) -> [String] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return [
            ("gemini-decision-1", decision1), ("gemma-4-26b-a4b-it", gemma),
            ("gemini-3.1-flash-lite", flashLite),
        ]
        .compactMap { name, entry in
            guard let date = formatter.date(from: entry.verifiedOn) else { return name }
            let days = now.timeIntervalSince(date) / 86_400
            return days > Double(staleAfterDays)
                ? "\(name) (verified \(entry.verifiedOn), \(entry.source))" : nil
        }
    }

    // MARK: - The ladder

    /// The ladder for `classifyType`, the only capability the enrichment
    /// pipeline routes today.
    ///
    /// ## There is deliberately no T3 rung here
    ///
    /// `docs/09-tiering.md` places T3 between T1 and T2 in general, and the
    /// YAML sketch in `docs/06` shows `t3-ask-user` before the paid rungs —
    /// but with a condition, `when: { stakes: low, reversible: true }`.
    /// **`Rung` cannot express that condition**, and `.askUser` returns
    /// unconditionally the moment it is reached. An unconditional T3 rung
    /// ahead of T2 would turn every capture the rules cannot type into a
    /// question for the user, and the T2 providers below would never be
    /// called at all.
    ///
    /// That is also not what the tiering doc asks for: its own table routes
    /// classify-type as **T0 → T1 → T2**, with no T3. T3 before T2 belongs to
    /// `judgeLink`, which nothing routes yet. When it does, `Rung` needs a
    /// predicate first.
    ///
    /// T1 is absent until B5. Adding it is a new rung at the front, not a
    /// change here.
    public static func classifyTypeLadder(apiKey: String) -> [Rung] {
        [
            // Decisions API first: a closed-set answer, natively calibrated
            // confidence, and ~124 tokens against Gemma's ~600 (ADR in
            // DecisionProvider). Cheapest and strictest, so it goes first.
            Rung(
                name: "t2-decision",
                action: .provider(
                    DecisionProvider(
                        model: "gemini-decision-1", apiKey: apiKey,
                        instructions: Prompts.classifyTypeSystem,
                        criteria: Prompts.typeCriteria)),
                model: "gemini-decision-1", tier: .t2),

            // Generate-and-parse fallback. Measured at 94% on the escalation
            // set, but its confidence is a constant 1.0 and carries no
            // information, so no threshold can gate it (B3/B4).
            Rung(
                name: "t2-gemma",
                action: .provider(
                    GoogleProvider(model: "gemma-4-26b-a4b-it", apiKey: apiKey, timeout: 60)),
                model: "gemma-4-26b-a4b-it", tier: .t2),

            // Last paid resort: 500 RPD is too small to carry the load, so it
            // exists to cover an outage of the two above, not to serve traffic.
            Rung(
                name: "t2-flash-lite",
                action: .provider(
                    GoogleProvider(model: "gemini-3.1-flash-lite", apiKey: apiKey, timeout: 60)),
                model: "gemini-3.1-flash-lite", tier: .t2),

            // Mandatory and always last. A capture is never lost.
            Rung(name: "degrade", action: .degrade, model: "-", tier: .t0),
        ]
    }

    /// Effort, when the capture states no duration.
    ///
    /// Same shape and same rungs as `classifyTypeLadder`: a closed set of six
    /// buckets, so the Decisions API expresses it natively and guard 1 is
    /// structural rather than defensive.
    ///
    /// **Why this field and not `dueAt`.** Guard 5 in
    /// `docs/07-harness-spec.md` is marked not-toggleable: "any model-supplied
    /// date" is rejected and "T0 parse is the only source". Effort carries no
    /// such invariant, and the cost of being one bucket out is a ranking
    /// position, not a missed deadline.
    ///
    /// **Why it is worth a call at all** (the Justification Test):
    /// `EffortBucket.unknown` is scored as medium — 60 minutes — so a capture
    /// whose size the rules cannot read does not score neutrally, it silently
    /// claims an hour of the day. Measured on real captures, the effort rules
    /// read **two of six**.
    public static func estimateEffortLadder(apiKey: String) -> [Rung] {
        [
            Rung(
                name: "t2-decision",
                action: .provider(
                    DecisionProvider(
                        model: "gemini-decision-1", apiKey: apiKey,
                        instructions: Prompts.effortSystem,
                        criteria: Prompts.effortCriteria)),
                model: "gemini-decision-1", tier: .t2),

            Rung(
                name: "t2-gemma",
                action: .provider(
                    GoogleProvider(model: "gemma-4-26b-a4b-it", apiKey: apiKey, timeout: 60)),
                model: "gemma-4-26b-a4b-it", tier: .t2),

            Rung(
                name: "t2-flash-lite",
                action: .provider(
                    GoogleProvider(model: "gemini-3.1-flash-lite", apiKey: apiKey, timeout: 60)),
                model: "gemini-3.1-flash-lite", tier: .t2),

            // Mandatory and always last. A capture is never lost.
            Rung(name: "degrade", action: .degrade, model: "-", tier: .t0),
        ]
    }

    /// Build the production router and register every rung's free-tier limits
    /// on the ledger.
    ///
    /// Registering the limits here rather than at the call site is the point:
    /// a rung whose budget was never registered spends against
    /// `ModelLimits.unlimited` and silently blows the free tier.
    ///
    /// - Parameter mode: `.replay` by default so a server's CI runs with no
    ///   API key and spends nothing. Production passes `.live`.
    public static func make(
        apiKey: String,
        ledger: BudgetLedger,
        cassettes: CassetteStore? = nil,
        mode: CassetteMode = .replay,
        guards: GuardConfig = .all
    ) async -> ModelRouter {
        await ledger.setLimits(decision1.limits, for: "gemini-decision-1")
        await ledger.setLimits(gemma.limits, for: "gemma-4-26b-a4b-it")
        await ledger.setLimits(flashLite.limits, for: "gemini-3.1-flash-lite")

        return ModelRouter(
            ladders: [
                .classifyType: classifyTypeLadder(apiKey: apiKey),
                .estimateEffort: estimateEffortLadder(apiKey: apiKey),
            ],
            ledger: ledger, cassettes: cassettes, mode: mode, guards: guards)
    }
}
