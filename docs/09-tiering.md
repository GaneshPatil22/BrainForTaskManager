# 09 — Tiering: where work is allowed to run

> A model is the most expensive, slowest, least reliable and least testable way
> to compute anything. It is the last resort, not the first.

`2 + 2` is a function. *"Explain why 0.1 + 0.2 ≠ 0.3"* is a model call. The skill
is knowing which bucket a problem is in — and **the default bucket is code.**

## The four tiers

| Tier | What | Cost | Latency | Testable | Explainable | Leaves machine |
|---|---|---|---|---|---|---|
| **T0** | Deterministic code: rules, grammars, math, set operations | ₹0 | µs | fully, property tests | fully | no |
| **T1** | Our own model: local embeddings, small classifier, per-user kNN | ₹0 | ~10ms | yes, offline | partly | no |
| **T2** | Global LLM: free-tier provider ladder | **quota** | 200ms–2s | only via replay | no | **yes** |
| **T3** | **Abstain — ask the user, one tap** | ₹0 | instant | n/a | fully | no |

**T3 sits between T1 and T2, not after T2.** For ambiguous, low-stakes, easily
reversible decisions, asking is cheaper and more honest than guessing — and the
answer becomes a training label for T1. A wrong model guess costs quota *and*
trust. An honest question costs one tap and buys a label.

## Tier assignment, per pipeline stage

| Stage | Tier | Why |
|---|---|---|
| Normalise text (NFC, whitespace, emoji, case) | **T0** | A model here would be absurd |
| Extract URLs / phone / amounts / OTPs | **T0** | Regex. Also the PII strip before anything leaves |
| **Parse dates** — "kal", "parso", "next Monday", "15 tarikh ko", "month end", "subah 9 baje" | **T0 always** | A grammar, not a model. An LLM parsing dates is the `2+2` mistake in its purest form |
| Parse explicit effort — "20 min", "2 ghante", "jaldi" | **T0** | If the user said how long, read it. Don't infer it |
| Classify type (task/idea/note/reminder/link) | **T0 → T1 → T2** | T0: URL-only → `link`; leading imperative verb → `task`; imperative + parsed date → `reminder`; "what if"/"idea:"/"kya agar" → `idea`. Only abstentions climb |
| Embed | **T1** | Local container. Never an API — 1,000 RPD would cap us at ~50 users (ADR-0005) |
| Retrieve ~10 candidates | **T0** | Vector search + filters. The model never searches |
| **Duplicate detection** | **T0 mostly** | Exact match after normalisation → duplicate. Cosine > 0.95 → duplicate. Trigram/Jaccard overlap → duplicate. Only the ambiguous band (~0.80–0.95) climbs |
| `relates` edges | **T0** | A relates edge *is* similarity in a band. Low-stakes and reversible. No model needed |
| `blocks` edges — **explicit** | **T0** | "after X", "once X is done", "X ke baad", "waiting for", "blocked by" + fuzzy title match → deterministic edge |
| `blocks` edges — **implicit** | **T2** | ← **the one place a model genuinely earns its keep.** Semantic dependency with no textual signal |
| Goal assignment | **T0 → T1 → T3** | Goal keyword in text → T0; kNN over past corrections → T1; novel → ask. Rarely T2 |
| Cycle rejection | **T0 always** | Graph algorithm. Non-negotiable |
| Leverage / ranking / quick wins / blocked | **T0 always** | Arithmetic |
| "Why" explanation | **T0 always** | Template filled from graph facts |

After this exercise the model's entire job description is one sentence:

> *For captures the rules could not resolve, and for candidate pairs in the
> ambiguous similarity band — is this a blocking dependency, a duplicate, or
> neither?*

A small, bounded, closed-set question.

## The AI Justification Test

**No model call enters the pipeline without an entry in `DECISIONS.md` recording:**

1. What deterministic approach was tried
2. Its **measured** coverage and accuracy — measured, not estimated
3. Why the remainder genuinely needs a model
4. Which tier, and what it falls back to when that tier is unavailable

If (2) cannot be written with a real number, the call does not ship.
Each proposed call is raised with Ganesh before it is built.

## Consequences for measurement

`B2.5` establishes the **T0 baseline** before any model is wired up, and B3's AI
work is scored as *delta over T0*, never in absolute terms. If a model beats the
rules by two points, the model call does not ship.

The scorecard reports three coverage numbers, not one:

- **T0 coverage** — % of fields resolved with zero model calls ← optimise this up
- **T0+T1 coverage** — % never leaving the machine
- **T2 rate** — % that costs quota and leaves the machine ← optimise this down

plus a retrospective column: **"would T0 have got this right?"** for every case a
model handled. That is how rules worth writing are discovered.
