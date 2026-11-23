# 06 — Model router

Requirement: **every layer replaceable without touching pipeline code.** Google
is one option, not a dependency.

## Shape

```
BrainPipeline  ──►  ModelRouter  ──►  [ rung, rung, rung, ... ]  ──►  LLMProvider
                         │
                         ├─ BudgetLedger    (RPM / TPM / RPD, per model AND per user)
                         ├─ CircuitBreaker  (per provider)
                         └─ CassetteStore   (record / replay)
```

The pipeline asks for a **capability** (`classifyType`, `judgeLink`), never for a
model. It never learns which rung answered. Swapping providers is a config edit
plus one adapter file.

```swift
protocol LLMProvider {
    var id: ProviderID { get }
    func complete(_ req: ModelRequest) async throws -> ModelResponse
    func estimateTokens(_ req: ModelRequest) -> Int   // BEFORE sending, not after
}
```

`estimateTokens` is required, not optional: TPM is enforced by counting before
the call. Counting after is how you get rate-limited.

## The ladder is code, with the limits as data

**Amended 2026-11-24.** This section used to say "configuration, not code" and
show `config/router.prod.yaml`. That file was never written, and nothing
loaded it — tests and CLI commands each built rungs their own way, so there
was no production ladder at all. It is now
`BrainProduction.ProductionRouter`, one supported entry point.

A YAML ladder needs a parser dependency Brain does not have, cannot be
type-checked, and drifts silently from the `Rung` API — which is exactly what
happened to the sketch below. What genuinely changes is the *limits*, and
those stay data, carrying the date and source of their last verification.

**The `when:` clause below does not exist in `Rung`.** `.askUser` returns the
moment it is reached, so an unconditional T3 rung placed before the T2 rungs
would make every escalated capture a question to the user and the T2
providers would never be called. T3-before-T2 needs a predicate on `Rung`
before it can be built. It is also not wanted for `classifyType`, which this
document's own table routes T0 → T1 → T2; T3 before T2 belongs to
`judgeLink`, which nothing routes yet.

The sketch is kept for the shape only:

```yaml
capabilities:
  judgeLink:
    - rung: t1-local
      provider: ml-service
      model: brain-classifier-v1
      budget: { rpm: null, tpm: null, rpd: null }
      accept_if_confidence_gte: 0.82      # chosen from the B5 cost/accuracy curve

    - rung: t3-ask-user                   # BEFORE spending quota
      when: { stakes: low, reversible: true }

    - rung: t2-decision
      provider: google
      model: gemini-decision-1
      budget: { rpm: 200, tpm: 50000, rpd: 10000 }

    - rung: t2-gemma
      provider: google
      model: gemma-4-26b
      budget: { rpm: 30, tpm: 16000, rpd: 14400 }

    - rung: t2-flash-lite
      provider: google
      model: gemini-3.1-flash-lite
      budget: { rpm: 15, tpm: 250000, rpd: 500 }

    - rung: degrade
      action: leave_unconfirmed           # a capture is NEVER lost
```

Rung order is the escalation order. `degrade` is mandatory and always last.

## Free-tier budgets

**Re-checked 2026-11-24.** Google's public rate-limit page
(`ai.google.dev/gemini-api/docs/rate-limits`, now a 301 to
`aistudio.google.com/docs/rate-limits`) no longer publishes a per-model
free-tier table. It says limits "can be viewed in Google AI Studio" and shows
only Gemini Decision 1: **200 RPM / 50,000 TPM / 10,000 RPD**, which matches
what we had.

The Gemma and Flash-Lite rows below therefore **cannot be verified without
signing in to Ganesh's account**. They are dated and sourced in
`ProductionRouter`, and `ProductionRouter.staleLimits(now:)` reports any row
older than 90 days so an out-of-date number does not quietly govern spending.

One thing the docs did settle: **RPD resets at midnight Pacific** — not on a
rolling 24-hour window, which is what `BudgetLedger` previously implemented.

### Verified 2026-11-22 from Ganesh's AI Studio account

| Model | RPM | TPM | **RPD** | Usable? |
|---|---|---|---|---|
| **Gemma 4 26B / 31B** | 30 | 16,000 | **14,400** | **yes — the workhorse** |
| **Gemini Decision 1** | 200 | 50,000 | **10,000** | **yes — closed-set** |
| Gemini 3.5 / 3.1 Flash Lite | 15 | 250,000 | 500 | escalation only |
| Gemini 3.8 Flash / 4 Hydrogen / 3.6 Flash | 5 | 250,000 | **20** | **no — 20/day is a toy** |
| Gemini Embedding 1 / 2 | 100 | 30,000 | 1,000 | **no — see ADR-0005** |

**The headline models are a trap.** The usable free capacity is in Gemma 4 and
Decision 1, which no vendor page advertises.

**Binding constraint is TPM, not RPM.** At ~1,200 tokens per enrichment, Gemma 4
allows ~13 calls/min — below its 30 RPM cap. Pacing the worker at ~10/min
consumes close to the full 14,400 RPD.

**Combined ceiling ≈ 24,400 LLM calls/day.** At ~0.8 T2 calls per capture and
20 captures/user/day, that is roughly **1,500 daily-active users** on free tier.

These numbers are **configuration with a verification date**, not constants.
Google changed free-tier limits unilaterally at least twice in 2026. The ledger
reads the config; re-verification is a recurring task at each phase gate.

## BudgetLedger

Tracks, per model **and per user**:

- rolling 60s request count (RPM)
- rolling 60s token count (TPM) — charged at `estimateTokens` before dispatch
- calendar-day request count (RPD), resetting on the provider's clock

**Per-user fair share is mandatory, not optional.** RPD is one shared bucket
across all users. Without it, one person pasting a 500-line brain dump starves
everyone else for the rest of the day. Default: no user may consume more than
`max(50, 2 × dailyBudget / activeUsers)` requests per day. Excess is queued, not
dropped — enrichment is asynchronous, so a delayed capture is invisible.

## Circuit breaker

Per provider. Opens after 5 consecutive failures or a 50% error rate over 20
calls; half-open probe after 60s. While open, that rung is skipped entirely and
the router falls through. Breaker state appears on every trace.

## Cassettes — record once, replay forever

Keyed by `sha256(promptVersion ‖ modelId ‖ normalisedInput)`.

| Mode | Behaviour |
|---|---|
| `replay` | **default for all eval and CI.** Offline, deterministic, free. A miss is a hard error, never a silent live call |
| `record` | calls live, writes the cassette, respects all budgets |
| `live` | no cassettes. Development only |

This is what makes the regression gate runnable on a 20 RPD budget. Cassettes
are committed; they are model outputs on synthetic data, not user content.

## Tracing

Every routed call logs: capability, rung chosen, rungs skipped and why
(budget / breaker / confidence), tier, tokens estimated vs. actual, latency,
guards fired, cassette hit or miss. Sufficient to replay any bad result.
